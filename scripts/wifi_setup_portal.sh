#!/usr/bin/env bash
set -Eeuo pipefail

note(){ echo "[wifi-setup] $*" >&2; }
err(){ echo "[wifi-setup][ERROR] $*" >&2; exit 1; }

IFACE="${WIFI_SETUP_IFACE:-wlan0}"

AP_CONN="${WIFI_SETUP_CONN_NAME:-consus-setup}"
AP_PREFIX="${WIFI_SETUP_SSID_PREFIX:-Consus-Setup}"
AP_PASS="${WIFI_SETUP_PASS:-}"

TARGET_CONN="${WIFI_TARGET_CONN_NAME:-consus-wifi}"

PORT="${WIFI_SETUP_PORT:-8080}"
TIMEOUT_S="${WIFI_SETUP_TIMEOUT_S:-900}"
CHECK_WAIT_S="${WIFI_SETUP_CHECK_WAIT_S:-2}"

HTML_FILE="${WIFI_SETUP_HTML_FILE:-/opt/edge-boot/portal/index.html}"
PY_FILE="${WIFI_SETUP_PY_FILE:-/opt/edge-boot/portal/wifi_portal.py}"

FORCE_FLAG_FILE="${WIFI_SETUP_FORCE_FLAG_FILE:-/opt/edge-boot/force_wifi_setup}"

command -v nmcli >/dev/null 2>&1 || err "nmcli not found"
command -v python3 >/dev/null 2>&1 || err "python3 not found"
command -v curl >/dev/null 2>&1 || err "curl not found"

have_internet() {
  curl -fsS -m 3 https://clients3.google.com/generate_204 >/dev/null 2>&1
}

ssid_suffix() {
  local h suf
  h="$(hostname 2>/dev/null || true)"
  suf="$(echo "$h" | tr -cd '0-9' | tail -c 4 || true)"
  if [[ -z "$suf" && -f /etc/machine-id ]]; then
    suf="$(tail -c 5 /etc/machine-id | tr -d '\n' || true)"
  fi
  [[ -z "$suf" ]] && suf="0000"
  echo "$suf"
}

nm_has_conn() {
  local name="$1"
  nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq "$name"
}

cleanup() {
  set +e
  [[ -n "${PY_PID:-}" ]] && kill "$PY_PID" >/dev/null 2>&1 || true
  nm_has_conn "$AP_CONN" && nmcli con down "$AP_CONN" >/dev/null 2>&1 || true
  nm_has_conn "$AP_CONN" && nmcli con delete "$AP_CONN" >/dev/null 2>&1 || true
  [[ -f "$FORCE_FLAG_FILE" ]] && rm -f "$FORCE_FLAG_FILE" >/dev/null 2>&1 || true
  set -e
}
trap cleanup EXIT

should_run_portal() {
  if have_internet; then
    note "Internet already up; no Wi-Fi setup needed."
    return 1
  fi

  if [[ -f "$FORCE_FLAG_FILE" ]]; then
    note "Force flag present; entering Wi-Fi setup portal."
    return 0
  fi

  # If consus-wifi exists, do NOT auto-expose portal (security).
  if nm_has_conn "$TARGET_CONN"; then
    note "Wi-Fi profile '${TARGET_CONN}' already exists; not starting portal automatically."
    return 1
  fi

  return 0
}

start_hotspot() {
  local suf ssid
  suf="$(ssid_suffix)"
  ssid="${AP_PREFIX}-${suf}"

  [[ -n "$AP_PASS" ]] || err "WIFI_SETUP_PASS is empty (must be set for client setup)"

  nmcli radio wifi on >/dev/null 2>&1 || true
  nmcli dev set "$IFACE" managed yes >/dev/null 2>&1 || true

  nm_has_conn "$AP_CONN" && nmcli con delete "$AP_CONN" >/dev/null 2>&1 || true

  note "Starting hotspot SSID=${ssid} on ${IFACE}"
  nmcli dev wifi hotspot ifname "$IFACE" con-name "$AP_CONN" ssid "$ssid" password "$AP_PASS" >/dev/null 2>&1 \
    || err "Failed to start hotspot."

  nmcli con up "$AP_CONN" >/dev/null 2>&1 || true

  note "Hotspot up. If page doesn't open automatically:"
  note "Try http://192.168.4.1:${PORT} then http://10.42.0.1:${PORT}"
}

start_portal_server() {
  [[ -f "$PY_FILE" ]] || err "Missing $PY_FILE"
  [[ -f "$HTML_FILE" ]] || err "Missing $HTML_FILE"

  export WIFI_SETUP_IFACE="$IFACE"
  export WIFI_TARGET_CONN_NAME="$TARGET_CONN"
  export WIFI_SETUP_PORT="$PORT"
  export WIFI_SETUP_HTML_FILE="$HTML_FILE"

  note "Starting portal server on port ${PORT}"
  python3 "$PY_FILE" >/dev/null 2>&1 &
  PY_PID=$!
}

wait_for_internet() {
  local start now
  start="$(date +%s)"
  note "Waiting for internet (timeout ${TIMEOUT_S}s)…"

  while true; do
    if have_internet; then
      note "Internet detected."
      return 0
    fi

    now="$(date +%s)"
    if (( now - start > TIMEOUT_S )); then
      return 1
    fi

    sleep "$CHECK_WAIT_S"
  done
}

if ! should_run_portal; then
  exit 0
fi

start_hotspot
start_portal_server

if wait_for_internet; then
  note "Wi-Fi setup complete; shutting down hotspot."
  exit 0
fi

err "Timed out waiting for Wi-Fi setup."
