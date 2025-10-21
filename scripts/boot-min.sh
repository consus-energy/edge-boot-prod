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

# ---------- Inverter link (eth0) ----------
discover_modbus_ip(){
  local ip=""
  local port="${MODBUS_PORT:-502}"
  local iface="${ETH_IFACE:-eth0}"
  local fallback_pi_ip="${EDGE_ETH_STATIC_IP:-192.168.86.10}"
  local fallback_prefix="${EDGE_ETH_PREFIX:-24}"

  # 0) If env already has a value, try it first
  if [[ -n "${MODBUS_IP:-}" ]]; then
    if nc -z -w1 "$MODBUS_IP" "$port" >/dev/null 2>&1; then echo "$MODBUS_IP"; return 0; fi
  fi

  # 1) If inverter link is ethernet, ensure iface is up
  if [[ "${LINK_INVERTER:-ethernet}" == "ethernet" ]]; then
    command -v nmcli >/dev/null 2>&1 && nmcli dev set "$iface" managed yes || true
    # try DHCP for a few seconds
    command -v nmcli >/dev/null 2>&1 && nmcli con show consus-eth0 >/dev/null 2>&1 || \
      nmcli con add type ethernet ifname "$iface" con-name consus-eth0 || true
    command -v nmcli >/dev/null 2>&1 && nmcli con mod consus-eth0 ipv4.method auto ipv6.method ignore || true
    command -v nmcli >/dev/null 2>&1 && nmcli con up consus-eth0 || true
    sleep 5

    # Determine subnet
    local cidr
    cidr=$(ip -4 addr show dev "$iface" | awk '/inet /{print $2; exit}')
    if [[ -z "$cidr" ]]; then
      # 2) No DHCP lease → apply static fallback (no gateway)
      note "No DHCP on ${iface}; applying static ${fallback_pi_ip}/${fallback_prefix}"
      command -v nmcli >/dev/null 2>&1 && nmcli con mod consus-eth0 ipv4.method manual ipv4.addresses "${fallback_pi_ip}/${fallback_prefix}" ipv4.gateway "" ipv4.dns "" || true
      command -v nmcli >/dev/null 2>&1 && nmcli con up consus-eth0 || true
      cidr="${fallback_pi_ip}/${fallback_prefix}"
      sleep 2
    fi

    # 3) Scan for Modbus TCP (prefer ARP neighbors, then quick sweep)
    local subnet base
    subnet=$(ipcalc -n "$cidr" 2>/dev/null | awk -F= '/Network/{print $2}')
    base="${subnet%/*}"
    note "Scanning ${iface} subnet (${cidr}) for Modbus TCP (502)…"

    # Probe known common address first (when you use fixed inverter IPs)
    for guess in "${MODBUS_IP:-}" "192.168.86.142"; do
      [[ -n "$guess" ]] || continue
      if nc -z -w1 "$guess" "$port" >/dev/null 2>&1; then ip="$guess"; break; fi
    done

    # ARP neighbors first (fast)
    if [[ -z "$ip" ]]; then
      ip neigh show dev "$iface" | awk '{print $1}' | while read -r host; do
        nc -z -w1 "$host" "$port" >/dev/null 2>&1 && { echo "$host"; break; }
      done | { read -r found || true; [[ -n "${found:-}" ]] && ip="$found"; }
    fi

    # Fallback: small sweep (first 50 hosts to keep it quick)
    if [[ -z "$ip" && -n "$base" ]]; then
      IFS=. read -r A B C D <<<"$(echo "$base")"
      for last in $(seq 2 51); do
        host="${A}.${B}.${C}.${last}"
        [[ "$host" == "$fallback_pi_ip" ]] && continue
        nc -z -w1 "$host" "$port" >/dev/null 2>&1 && { ip="$host"; break; }
      done
    fi
  fi

  [[ -n "$ip" ]] && echo "$ip"
}

found_ip="$(discover_modbus_ip || true)"
if [[ -n "$found_ip" ]]; then
  note "Detected inverter Modbus at ${found_ip}:${MODBUS_PORT:-502}"
  # Write back atomically to env.edge
  tmp=$(mktemp)
  awk -v kv="MODBUS_IP=${found_ip}" '
    BEGIN{done=0}
    /^MODBUS_IP=/ { if(!done){print kv; done=1; next} }
    {print}
    END{ if(!done) print kv }
  ' "$ENV_FILE" > "$tmp" && sudo install -m 0644 "$tmp" "$ENV_FILE" && rm -f "$tmp"
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
