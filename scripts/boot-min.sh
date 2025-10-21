#!/usr/bin/env bash
# Consus Edge — MINIMAL PROVISIONING (no autostart). Safe to run every boot.
set -Eeuo pipefail

note(){ echo "[BOOT] $*"; }
err(){ echo "[BOOT][ERROR] $*" >&2; exit 1; }

ENV_FILE="${ENV_FILE:-/opt/edge-boot/env.edge}"
SA_JSON="${SA_JSON:-/opt/edge-boot/secrets/key.json}"
RUN_CONTAINER="${RUN_CONTAINER:-0}"   # must stay 0 here (no autostart)
DOCKER="docker"; command -v docker >/dev/null 2>&1 || DOCKER="sudo docker"
if ! groups "$USER" | grep -q '\bdocker\b' 2>/dev/null; then DOCKER="sudo docker"; fi

[ -f "$ENV_FILE" ] || err "Missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

# --- Modbus port is ALWAYS 502 (force it, regardless of env) ---
MODBUS_PORT=502

# ---------- Host prep ----------
sudo mkdir -p /opt/edge-boot/data/spool /opt/edge-boot/secrets
sudo chown -R "$USER":"$USER" /opt/edge-boot || true

# DNS preference (helps avoid IPv6 hiccups)
sudo mkdir -p /etc/docker
if [ ! -f /etc/docker/daemon.json ] || ! grep -q '"dns"' /etc/docker/daemon.json 2>/dev/null; then
  echo '{"dns":["1.1.1.1","8.8.8.8"],"ipv6":false}' | sudo tee /etc/docker/daemon.json >/dev/null
  sudo systemctl enable --now docker
  sudo systemctl restart docker
else
  sudo systemctl enable --now docker
fi

# ---------- Optional Wi-Fi provisioning ----------
if [[ "${WIFI_PROVISION_ENABLE:-0}" == "1" ]]; then
  if command -v nmcli >/dev/null 2>&1; then
    IFACE="${WIFI_IFACE:-wlan0}"
    CONN_NAME="${WIFI_SSID:-consus-wifi}"
    note "Provisioning Wi-Fi SSID=${WIFI_SSID:-?} on ${IFACE} via NetworkManager…"
    nmcli radio wifi on || true
    if nmcli -t -f NAME connection show | grep -Fxq "$CONN_NAME"; then
      nmcli connection modify "$CONN_NAME" connection.interface-name "$IFACE" 2>/dev/null || true
    else
      nmcli connection add type wifi ifname "$IFACE" con-name "$CONN_NAME" ssid "${WIFI_SSID}"
    fi
    if [[ -n "${WIFI_PASS:-}" ]]; then
      nmcli connection modify "$CONN_NAME" wifi-sec.key-mgmt wpa-psk
      nmcli connection modify "$CONN_NAME" wifi-sec.psk "$WIFI_PASS"
    else
      nmcli connection modify "$CONN_NAME" wifi-sec.key-mgmt "none"
    fi
    nmcli connection modify "$CONN_NAME" ipv4.method "${WIFI_IPV4_METHOD:-auto}"
    nmcli connection modify "$CONN_NAME" ipv6.method "ignore"
    nmcli connection modify "$CONN_NAME" ipv4.ignore-auto-dns yes
    nmcli connection modify "$CONN_NAME" ipv4.dns "1.1.1.1 8.8.8.8"
    nmcli device disconnect "$IFACE" >/dev/null 2>&1 || true
    nmcli connection up "$CONN_NAME" ifname "$IFACE" || true
  else
    note "NetworkManager not present; skipping Wi-Fi provisioning."
  fi
fi

# ---------- Inverter link (eth0 / or wlan if LINK_INVERTER=wifi) ----------
discover_modbus_ip(){
  local port="502"  # fixed
  local link="${LINK_INVERTER:-ethernet}"
  local iface
  local ip=""
  local cidr=""
  local fallback_pi_ip="${EDGE_ETH_STATIC_IP:-192.168.86.10}"
  local fallback_prefix="${EDGE_ETH_PREFIX:-24}"

  # Prefer env value if already reachable
  if [[ -n "${MODBUS_IP:-}" ]]; then
    if nc -z -w1 "$MODBUS_IP" "$port" >/dev/null 2>&1; then echo "$MODBUS_IP"; return 0; fi
  fi

  # Pick interface by link type
  if [[ "$link" == "wifi" ]]; then
    iface="${WIFI_IFACE:-wlan0}"
  else
    iface="${ETH_IFACE:-eth0}"
  fi

  # Ensure iface up / address present
  if [[ "$link" == "ethernet" ]]; then
    if command -v nmcli >/dev/null 2>&1; then
      nmcli dev set "$iface" managed yes || true
      nmcli -t -f NAME connection show | grep -Fxq consus-eth0 || \
        nmcli connection add type ethernet ifname "$iface" con-name consus-eth0 || true
      nmcli connection modify consus-eth0 ipv4.method auto ipv6.method ignore || true
      nmcli connection up consus-eth0 || true
    fi
    sleep 5
    cidr="$(ip -4 addr show dev "$iface" | awk '/inet /{print $2; exit}')"
    if [[ -z "$cidr" ]]; then
      note "No DHCP on ${iface}; applying static ${fallback_pi_ip}/${fallback_prefix}"
      if command -v nmcli >/dev/null 2>&1; then
        nmcli connection modify consus-eth0 ipv4.method manual \
          ipv4.addresses "${fallback_pi_ip}/${fallback_prefix}" ipv4.gateway "" ipv4.dns "" || true
        nmcli connection up consus-eth0 || true
      else
        sudo ip addr add "${fallback_pi_ip}/${fallback_prefix}" dev "$iface" 2>/dev/null || true
        sudo ip link set "$iface" up 2>/dev/null || true
      fi
      sleep 2
      cidr="${fallback_pi_ip}/${fallback_prefix}"
    fi
  else
    # wifi link: just read existing cidr
    cidr="$(ip -4 addr show dev "$iface" | awk '/inet /{print $2; exit}')"
  fi

  # Probe common guesses first
  for guess in "${MODBUS_IP:-}" "192.168.86.142"; do
    [[ -n "$guess" ]] || continue
    if nc -z -w1 "$guess" "$port" >/dev/null 2>&1; then ip="$guess"; break; fi
  done

  # ARP neighbors (fast)
  if [[ -z "$ip" ]]; then
    ip neigh show dev "$iface" | awk '{print $1}' | while read -r host; do
      nc -z -w1 "$host" "$port" >/dev/null 2>&1 && { echo "$host"; break; }
    done | { read -r found || true; [[ -n "${found:-}" ]] && ip="$found"; }
  fi

  # Small sweep (first ~50 hosts in subnet)
  if [[ -z "$ip" && -n "$cidr" ]]; then
    local base A B C host
    base="${cidr%/*}"
    IFS=. read -r A B C _ <<<"$base"
    for last in $(seq 2 51); do
      host="${A}.${B}.${C}.${last}"
      [[ "$host" == "$fallback_pi_ip" ]] && continue
      nc -z -w1 "$host" "$port" >/dev/null 2>&1 && { ip="$host"; break; }
    done
  fi

  [[ -n "$ip" ]] && echo "$ip"
}

found_ip="$(discover_modbus_ip || true)"
if [[ -n "$found_ip" ]]; then
  note "Detected inverter Modbus at ${found_ip}:502"
  # Write back atomically to env.edge
  tmp=$(mktemp)
  awk -v kv="MODBUS_IP=${found_ip}" '
    BEGIN{done=0}
    /^MODBUS_IP=/ { if(!done){print kv; done=1; next} }
    {print}
    END{ if(!done) print kv }
  ' "$ENV_FILE" > "$tmp" && sudo install -m 0644 "$tmp" "$ENV_FILE" && rm -f "$tmp"

  # ---------- Report MODBUS target to BatteryRegistry (PATCH /batteries/{consus_id}) ----------
  # Prefer 'consus_id' from env; fallback to legacy 'group_id' if present
  TARGET_ID="${consus_id:-${group_id:-}}"
  if [[ -n "${TARGET_ID}" && -n "${api_base_url:-}" && -n "${API_KEY:-}" ]]; then
    PATCH_URL="${api_base_url%/}/batteries/${TARGET_ID}"

    read -r -d '' _JSON <<EOF
{
  "MODBUS_IP": "${found_ip}",
  "MODBUS_PORT": 502
}
EOF

    note "PATCH ${PATCH_URL} with MODBUS_IP=${found_ip}, MODBUS_PORT=502"
    code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' \
      -X PATCH "${PATCH_URL}" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "Content-Type: application/json" \
      --data "${_JSON}")" || code="000"

    if [[ "$code" =~ ^(200|201|204)$ ]]; then
      note "BatteryRegistry updated (${code})."
    else
      note "PATCH failed (${code}). Local env updated; backend can be retried later."
    fi
  else
    note "Skipping upstream PATCH (missing consus_id/group_id or api_base_url/API_KEY)."
  fi
else
  note "Modbus IP not discovered yet; will rely on future retry/manual set."
fi

# ---------- Artifact Registry login + image pull ----------
if [[ -f "$SA_JSON" ]]; then
  REG_HOST="$(echo "${EDGE_IMAGE:-europe-west2-docker.pkg.dev/consus-ems/consus-edge/edge-image:main}" | awk -F/ '{print $1}')"
  getent hosts "$REG_HOST" >/dev/null 2>&1 || note "DNS not yet ready for $REG_HOST; will try anyway."
  note "Logging into $REG_HOST…"
  cat "$SA_JSON" | $DOCKER login -u _json_key --password-stdin "$REG_HOST" >/dev/null 2>&1 || note "GAR login failed (will still try pull)"
fi

IMG="${EDGE_IMAGE:-europe-west2-docker.pkg.dev/consus-ems/consus-edge/edge-image:main}"
note "Pulling image: $IMG"
$DOCKER pull "$IMG" >/dev/null 2>&1 || note "Pull failed now; image may already exist."

# ---------- Respect no-autostart ----------
if [[ "$RUN_CONTAINER" != "1" ]]; then
  note "Provisioning complete (no autostart). Start later via edge-start.sh"
  exit 0
fi

# (kept for completeness; in this “min” script RUN_CONTAINER stays 0)
note "RUN_CONTAINER=1 requested, but this build is provision-only."
exit 0
