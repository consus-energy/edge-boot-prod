#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[net-watchdog] $*" >&2; }

ENV_FILE="${ENV_FILE:-/opt/edge-boot/env/env.edge}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  . "$ENV_FILE"
  set +a
fi

INTERVAL_SECONDS="${NET_WD_INTERVAL_SECONDS:-10}"
FAILS_NEEDED="${NET_WD_FAILS_NEEDED:-6}"
COOLDOWN_SECONDS="${NET_WD_COOLDOWN_SECONDS:-300}"

LINK_INTERNET="${LINK_INTERNET:-wifi}"
ETH_IFACE="${ETH_IFACE:-eth0}"
WIFI_IFACE="${WIFI_IFACE:-wlan0}"

# ping targets (comma-separated). include gw + public dns by default.
NET_PING_TARGETS="${NET_PING_TARGETS:-1.1.1.1,8.8.8.8}"

STATE_DIR="/run/consus-net-watchdog"
FAIL_FILE="${STATE_DIR}/fails"
LAST_ACTION_FILE="${STATE_DIR}/last_action"

mkdir -p "$STATE_DIR"
touch "$FAIL_FILE" "$LAST_ACTION_FILE" 2>/dev/null || true

eth_link_up() {
  ip link show "$ETH_IFACE" >/dev/null 2>&1 || return 1
  [[ "$(cat "/sys/class/net/${ETH_IFACE}/operstate" 2>/dev/null || echo down)" == "up" ]]
}

# get default gateway if present
default_gw() {
  ip route | awk '/default/ {print $3; exit}' || true
}

# connectivity: ping gw + ping a couple of targets
connectivity_ok() {
  local gw targets t
  gw="$(default_gw)"
  [[ -n "${gw:-}" ]] || return 1
  ping -c1 -W1 "$gw" >/dev/null 2>&1 || return 1

  IFS=',' read -r -a targets <<<"$NET_PING_TARGETS"
  for t in "${targets[@]}"; do
    [[ -n "$t" ]] || continue
    ping -c1 -W1 "$t" >/dev/null 2>&1 && return 0
  done
  return 1
}

# pick the wifi connection name to bring up (avoid wrong saved network)
wifi_conn_name() {
  # prefer explicit WIFI_SSID if you set it
  if [[ -n "${WIFI_SSID:-}" && "${WIFI_SSID}" != "__SITE_WIFI_SSID__" ]]; then
    echo "$WIFI_SSID"
    return 0
  fi
  # else: use currently active connection on that iface, if any
  if command -v nmcli >/dev/null 2>&1; then
    nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v d="$WIFI_IFACE" '$2==d{print $1; exit}'
  fi
}

if command -v iw >/dev/null 2>&1 && ip link show "$WIFI_IFACE" >/dev/null 2>&1; then
  iw dev "$WIFI_IFACE" set power_save off >/dev/null 2>&1 || true
fi

while true; do
  now=$(date +%s)
  last_action=$(cat "$LAST_ACTION_FILE" 2>/dev/null || echo 0)

  if [ $((now - last_action)) -lt "$COOLDOWN_SECONDS" ]; then
    sleep "$INTERVAL_SECONDS"
    continue
  fi

  if connectivity_ok; then
    echo 0 >"$FAIL_FILE"
    sleep "$INTERVAL_SECONDS"
    continue
  fi

  fails=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
  fails=$((fails + 1))
  echo "$fails" >"$FAIL_FILE"

  if [ "$fails" -lt "$FAILS_NEEDED" ]; then
    sleep "$INTERVAL_SECONDS"
    continue
  fi

  # final double-check before acting (avoids flapping if it recovered naturally)
  if connectivity_ok; then
    echo 0 >"$FAIL_FILE"
    sleep "$INTERVAL_SECONDS"
    continue
  fi

  echo "$now" >"$LAST_ACTION_FILE"
  echo 0 >"$FAIL_FILE"

  if [[ "$LINK_INTERNET" != "wifi" ]] || eth_link_up; then
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
      log "Connectivity down; ethernet mode detected (or eth up). Restarting NetworkManager only."
      systemctl restart NetworkManager || true
    elif systemctl is-active --quiet dhcpcd 2>/dev/null; then
      log "Connectivity down; ethernet mode detected. Restarting dhcpcd."
      systemctl restart dhcpcd || true
    else
      log "Connectivity down; ethernet mode detected. No NM/dhcpcd to restart."
    fi
    sleep "$INTERVAL_SECONDS"
    continue
  fi

  if command -v nmcli >/dev/null 2>&1 && ip link show "$WIFI_IFACE" >/dev/null 2>&1; then
    CONN_NAME="$(wifi_conn_name || true)"
    if [[ -n "${CONN_NAME:-}" ]]; then
      log "Connectivity down; bringing up wifi connection '${CONN_NAME}' on ${WIFI_IFACE}"
      nmcli dev disconnect "$WIFI_IFACE" >/dev/null 2>&1 || true
      sleep 2
      nmcli connection up "$CONN_NAME" ifname "$WIFI_IFACE" >/dev/null 2>&1 || true
    else
      log "Connectivity down; reconnecting ${WIFI_IFACE} via NetworkManager (no conn name found)"
      nmcli dev disconnect "$WIFI_IFACE" >/dev/null 2>&1 || true
      sleep 2
      nmcli dev connect "$WIFI_IFACE" >/dev/null 2>&1 || true
    fi
    sleep "$INTERVAL_SECONDS"
    continue
  fi

  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    log "Connectivity down; restarting NetworkManager"
    systemctl restart NetworkManager || true
    sleep "$INTERVAL_SECONDS"
    continue
  fi

  if systemctl is-active --quiet dhcpcd 2>/dev/null; then
    log "Connectivity down; restarting dhcpcd"
    systemctl restart dhcpcd || true
  fi

  sleep "$INTERVAL_SECONDS"
done
