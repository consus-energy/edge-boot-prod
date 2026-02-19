#!/usr/bin/env bash
# Consus Edge — MINIMAL PROVISIONING (no autostart). Safe to run every boot.
set -Eeuo pipefail

note(){ echo "[BOOT] $*" >&2; }
err(){ echo "[BOOT][ERROR] $*" >&2; exit 1; }

# ---- Paths aligned with deploy_edge.sh ----
ENV_FILE="${ENV_FILE:-/opt/edge-boot/env/env.edge}"
SA_JSON="${SA_JSON:-/opt/edge-boot/secrets/key.json}"
RUN_CONTAINER="${RUN_CONTAINER:-0}"   # must stay 0 here (no autostart)

# ---- Docker command (no $USER under systemd) ----
DOCKER="docker"
command -v docker >/dev/null 2>&1 || DOCKER="sudo docker"
if [ "$(id -u)" -ne 0 ]; then
  id -nG 2>/dev/null | grep -q '\bdocker\b' || DOCKER="sudo docker"
fi

# ---------- Health guard (RAM + swap) ----------
health_guard() {
  local min_mem_mb="${MIN_MEM_MB:-200}"
  local max_swap_used_pct="${MAX_SWAP_USED_PCT:-50}"

  local mem_avail_kb mem_avail_mb
  mem_avail_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  mem_avail_mb="$(( mem_avail_kb / 1024 ))"

  local swap_total_kb swap_free_kb swap_used_pct
  swap_total_kb="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  swap_free_kb="$(awk '/SwapFree:/  {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [ "${swap_total_kb:-0}" -gt 0 ]; then
    swap_used_pct="$(( ( (swap_total_kb - swap_free_kb) * 100 ) / swap_total_kb ))"
  else
    swap_used_pct=0
  fi

  if [ "${mem_avail_mb:-0}" -lt "$min_mem_mb" ]; then
    note "Low RAM: MemAvailable=${mem_avail_mb}MB (<${min_mem_mb}MB). Dropping caches (best effort)."
    sudo sync >/dev/null 2>&1 || true
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
  fi

  if [ "${swap_used_pct:-0}" -ge "$max_swap_used_pct" ]; then
    note "High swap usage: ${swap_used_pct}% (>=${max_swap_used_pct}%)."
  fi
}

# ---------- Minimal disk cleanup (only when low) ----------
disk_guard() {
  local free_mb
  free_mb="$(df -Pm / | awk 'NR==2{print $4}')"
  if [ "${free_mb:-0}" -ge 1024 ]; then
    note "Disk OK (${free_mb}MB free on /)."
    return 0
  fi

  note "Low disk (${free_mb}MB free on /). Clearing old logs + docker logs + prune…"

  # journald (size cap)
  if command -v journalctl >/dev/null 2>&1; then
    sudo journalctl --vacuum-size=200M >/dev/null 2>&1 || true
  fi

  # truncate big docker json logs
  if [ -d /var/lib/docker/containers ]; then
    sudo find /var/lib/docker/containers -name '*-json.log' -type f -size +50M -print \
      -exec sudo sh -c 'truncate -s 0 "$1"' _ {} \; >/dev/null 2>&1 || true
  fi

  # delete rotated/compressed logs
  sudo find /var/log -type f \( -name "*.gz" -o -name "*.[0-9]" -o -name "*.1" \) -delete >/dev/null 2>&1 || true

  # docker prune
  $DOCKER system prune -a -f --volumes >/dev/null 2>&1 || true

  free_mb="$(df -Pm / | awk 'NR==2{print $4}')"
  note "After cleanup: ${free_mb}MB free on /"
}

# ---------- Periodic guard timer (repo-managed) ----------
install_guard_timer() {
  local edge_start="/opt/edge-boot/scripts/edge-start.sh"

  if [ ! -x "$edge_start" ]; then
    note "Guard timer skipped: missing executable ${edge_start}"
    return 0
  fi

  sudo tee /etc/systemd/system/consus-guard.service >/dev/null <<EOF
[Unit]
Description=Consus Edge guard (disk+health)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${edge_start} --guard-once
EOF

  sudo tee /etc/systemd/system/consus-guard.timer >/dev/null <<'EOF'
[Unit]
Description=Run Consus Edge guard periodically

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  sudo systemctl daemon-reload >/dev/null 2>&1 || true
  sudo systemctl enable --now consus-guard.timer >/dev/null 2>&1 || true
  note "Guard timer installed/enabled (15 min)."
}

# ---------- Enforce 3-day journal retention (strict) ----------
enforce_journald_retention() {
  local conf="/etc/systemd/journald.conf"
  sudo touch "$conf" || true
  sudo sed -i \
    -e 's/^[#[:space:]]*SystemMaxUse=.*/SystemMaxUse=200M/' \
    -e 's/^[#[:space:]]*SystemMaxFileSize=.*/SystemMaxFileSize=20M/' \
    -e 's/^[#[:space:]]*MaxRetentionSec=.*/MaxRetentionSec=3day/' \
    "$conf" 2>/dev/null || true
  grep -q '^[#[:space:]]*MaxRetentionSec=' "$conf" || echo 'MaxRetentionSec=3day' | sudo tee -a "$conf" >/dev/null
  sudo systemctl restart systemd-journald >/dev/null 2>&1 || true
  sudo journalctl --vacuum-time=3d >/dev/null 2>&1 || true
}

[ -f "$ENV_FILE" ] || err "Missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

# --- Modbus port is ALWAYS 502 (force it, regardless of env) ---
MODBUS_PORT=502

# ---------- Host prep ----------
sudo mkdir -p /opt/edge-boot/data/spool /opt/edge-boot/secrets
sudo chown -R "${SUDO_USER:-root}":"${SUDO_USER:-root}" /opt/edge-boot || true

# ---------- Minimal Docker hardening (prevents SD fill-ups) ----------
sudo mkdir -p /etc/docker
DAEMON_JSON="/etc/docker/daemon.json"

sudo tee "$DAEMON_JSON" >/dev/null <<'JSON'
{
  "dns": ["1.1.1.1", "8.8.8.8"],
  "ipv6": false,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
JSON

sudo systemctl enable --now docker
sudo systemctl restart docker

# ---------- Log retention + periodic guard ----------
enforce_journald_retention
install_guard_timer

# ---- Minimal anti-disk-fill + health check (run once now) ----
disk_guard
health_guard

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

# ---------- Client Wi-Fi setup portal (only when needed) ----------
if [[ "${WIFI_SETUP_ENABLE:-0}" == "1" ]]; then
  if command -v nmcli >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    note "Wi-Fi setup portal enabled; checking connectivity…"
    if ! curl -fsS -m 3 https://clients3.google.com/generate_204 >/dev/null 2>&1; then
      note "No internet detected; starting Wi-Fi setup portal…"
      /opt/edge-boot/scripts/wifi_setup_portal.sh || note "Wi-Fi setup portal exited with failure or timeout."
    else
      note "Internet OK; skipping Wi-Fi setup portal."
    fi
  else
    note "Wi-Fi setup portal enabled but nmcli/python3 missing; skipping."
  fi
fi

# ---------- Inverter link (eth0 / or wlan if LINK_INVERTER=wifi) ----------
discover_modbus_ip(){
  local port="502"  # fixed
  local link="${LINK_INVERTER:-ethernet}"
  local iface
  local ip=""
  local cidr=""
  local found_method=""
  local fallback_pi_ip="${EDGE_ETH_STATIC_IP:-192.168.86.10}"
  local fallback_prefix="${EDGE_ETH_PREFIX:-24}"

  if [[ "$link" == "wifi" ]]; then
    iface="${WIFI_IFACE:-wlan0}"
  else
    iface="${ETH_IFACE:-eth0}"
  fi
  note "Discovery: link=${link}, iface=${iface}"

  if [[ -n "${MODBUS_IP:-}" ]]; then
    note "Discovery: trying MODBUS_IP from env (${MODBUS_IP}) on port ${port}"
    if nc -z -w1 "$MODBUS_IP" "$port" >/dev/null 2>&1; then
      found_method="env"
      echo "$MODBUS_IP"
      return 0
    else
      note "Discovery: MODBUS_IP=${MODBUS_IP} not reachable on ${port}; continuing"
    fi
  else
    note "Discovery: no MODBUS_IP in env; proceeding to scan"
  fi

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
      note "Discovery: no DHCP address on ${iface}; applying static ${fallback_pi_ip}/${fallback_prefix}"
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
    cidr="$(ip -4 addr show dev "$iface" | awk '/inet /{print $2; exit}')"
  fi
  [[ -n "$cidr" ]] && note "Discovery: using CIDR ${cidr}" || note "Discovery: no IPv4 CIDR on ${iface}"

  for guess in "${MODBUS_IP:-}"; do
    [[ -n "$guess" ]] || continue
    note "Discovery: probing configured guess ${guess}:${port}"
    if nc -z -w1 "$guess" "$port" >/dev/null 2>&1; then
      found_method="guess"
      ip="$guess"; break
    fi
  done

  if [[ -z "$ip" ]]; then
    note "Discovery: probing ARP neighbours on ${iface} for Modbus ${port}…"
    ip neigh show dev "$iface" | awk '{print $1}' | while read -r host; do
      nc -z -w1 "$host" "$port" >/dev/null 2>&1 && { echo "$host"; break; }
    done | { read -r found || true; [[ -n "${found:-}" ]] && ip="$found" && found_method="arp"; }
    [[ -n "$ip" ]] && note "Discovery: ARP hit ${ip}"
  fi

  if [[ -z "$ip" && -n "$cidr" ]]; then
    local base A B C host
    base="${cidr%/*}"
    IFS=. read -r A B C _ <<<"$base"
    note "Discovery: sweeping ${base}/24 for Modbus ${port}…"
    for last in $(seq 2 254); do
      host="${A}.${B}.${C}.${last}"
      [[ "$host" == "$fallback_pi_ip" ]] && continue
      if nc -z -w1 "$host" "$port" >/dev/null 2>&1; then
        ip="$host"; found_method="sweep"; break
      fi
    done
    [[ -n "$ip" ]] && note "Discovery: sweep hit ${ip}" || note "Discovery: sweep found nothing on ${base}/24"
  fi

  [[ -n "$ip" ]] && { note "Discovery: success via ${found_method:-unknown}: ${ip}:${port}"; echo "$ip"; }
}

found_ip="$(discover_modbus_ip || true)"
if [[ -n "$found_ip" ]]; then
  note "Detected inverter Modbus at ${found_ip}:502"
  tmp="$(dirname "$ENV_FILE")/.env.edge.tmp.$$"
  awk -v kv="MODBUS_IP=${found_ip}" '
    BEGIN{done=0}
    /^MODBUS_IP=/ { if(!done){print kv; done=1; next} }
    {print}
    END{ if(!done) print kv }
  ' "$ENV_FILE" > "$tmp" && sudo install -m 0644 "$tmp" "$ENV_FILE" && rm -f "$tmp"

  TARGET_ID="${consus_id:-${group_id:-}}"
  if [[ -n "${TARGET_ID}" && -n "${api_base_url:-}" && -n "${API_KEY:-}" ]]; then
    PATCH_URL="${api_base_url%/}/batteries/${TARGET_ID}"
    _JSON=$(cat <<'EOF'
{
  "MODBUS_IP": "__FOUND_IP__",
  "MODBUS_PORT": 502
}
EOF
)
    _JSON="${_JSON/__FOUND_IP__/${found_ip}}"
    note "PATCH ${PATCH_URL} with MODBUS_IP=${found_ip}, MODBUS_PORT=502"

    set +e
    code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' \
             -X PATCH "${PATCH_URL}" \
             -H "Authorization: Bearer ${API_KEY}" \
             -H "Content-Type: application/json" \
             --data "${_JSON}")"
    curl_status=$?
    set -e

    if [[ $curl_status -ne 0 ]]; then
      note "PATCH failed (curl error ${curl_status}). Local env updated; backend can be retried later."
    elif [[ "$code" =~ ^(200|201|204)$ ]]; then
      note "BatteryRegistry updated (${code})."
    else
      note "PATCH failed (HTTP ${code}). Local env updated; backend can be retried later."
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

note "RUN_CONTAINER=1 requested, but this build is provision-only."
exit 0
