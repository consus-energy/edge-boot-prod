#!/usr/bin/env bash
set -euo pipefail

# Consus net test
# - non-destructive by default
# - writes a timestamped log file
# - optional disruptive wifi disconnect/reconnect (DO_DISRUPTIVE=1)
# - optional API probe (DO_API_PROBE=1) uses health_endpoint if present, else ingest_endpoint
# - optional Modbus TCP probe (DO_MODBUS_PROBE=1) checks TCP connect only

OUT_DIR="${1:-/tmp/consus-net-test}"

DURATION_MIN="${DURATION_MIN:-20}"        # ping soak duration
PING_INTERVAL="${PING_INTERVAL:-10}"      # seconds

DO_IDLE_TEST="${DO_IDLE_TEST:-1}"         # 1 = do an "idle then probe" test
IDLE_MIN="${IDLE_MIN:-15}"                # how long to be idle (no traffic from this script) before probing

DO_CHURN_TEST="${DO_CHURN_TEST:-1}"       # 1 = do HTTPS churn test
CHURN_ROUNDS="${CHURN_ROUNDS:-50}"        # number of curls
CHURN_SLEEP="${CHURN_SLEEP:-1}"           # seconds between curls

DO_DISRUPTIVE="${DO_DISRUPTIVE:-0}"       # 1 = disconnect/reconnect wlan0 once
DISRUPTIVE_DOWN_SECONDS="${DISRUPTIVE_DOWN_SECONDS:-20}"

DO_API_PROBE="${DO_API_PROBE:-1}"         # 1 = hit API health endpoint (preferred) or ingest endpoint (fallback)
API_INTERVAL="${API_INTERVAL:-30}"         # seconds between hits
API_ROUNDS="${API_ROUNDS:-20}"            # number of hits
API_METHOD="${API_METHOD:-GET}"            # GET (recommended for /health). If set to POST and ingest_endpoint exists, will POST.

DO_MODBUS_PROBE="${DO_MODBUS_PROBE:-1}"   # 1 = TCP connect checks to MODBUS_IP:MODBUS_PORT
MODBUS_INTERVAL="${MODBUS_INTERVAL:-10}"   # seconds between checks
MODBUS_ROUNDS="${MODBUS_ROUNDS:-60}"       # number of checks

# ---- Helpers ----
mkdir -p "$OUT_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$OUT_DIR/net_test_${TS}.log"

log(){ echo "[$(date -Is)] $*" | tee -a "$LOG" >&2; }

# ---- Load env.edge (single source of truth) ----
ENV_FILE="${ENV_FILE:-/opt/edge-boot/env/env.edge}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
else
  log "WARNING: env.edge not found at $ENV_FILE (API/MODBUS probes may be skipped)"
fi

WIFI_IFACE="${WIFI_IFACE:-wlan0}"
ETH_IFACE="${ETH_IFACE:-eth0}"

# ---- Baseline snapshot ----
log "Starting net test"
log "Host: $(hostname)"
log "Kernel: $(uname -a)"
log "OUT_DIR: $OUT_DIR"
log "Ping soak: ${DURATION_MIN} min @ ${PING_INTERVAL}s"
log "Idle test: ${DO_IDLE_TEST} (idle ${IDLE_MIN} min)"
log "Churn test: ${DO_CHURN_TEST} (rounds ${CHURN_ROUNDS})"
log "Disruptive: ${DO_DISRUPTIVE} (down ${DISRUPTIVE_DOWN_SECONDS}s)"
log "API probe: ${DO_API_PROBE} (${API_METHOD}, rounds ${API_ROUNDS} @ ${API_INTERVAL}s)"
log "Modbus probe: ${DO_MODBUS_PROBE} (rounds ${MODBUS_ROUNDS} @ ${MODBUS_INTERVAL}s)"
log ""

log "=== BASELINE ==="
{
  echo "date: $(date -Is)"
  echo ""
  echo "--- ip addr ---"
  ip addr show
  echo ""
  echo "--- ip route ---"
  ip route
  echo ""
  if command -v nmcli >/dev/null 2>&1; then
    echo "--- nmcli connections (all) ---"
    nmcli -t -f NAME,TYPE,DEVICE,AUTOCONNECT,AUTOCONNECT-PRIORITY connection show || true
    echo ""
    echo "--- nmcli connections (active) ---"
    nmcli -t -f NAME,DEVICE connection show --active || true
    echo ""
  fi
  if command -v iw >/dev/null 2>&1 && ip link show "$WIFI_IFACE" >/dev/null 2>&1; then
    echo "--- iw link (${WIFI_IFACE}) ---"
    iw dev "$WIFI_IFACE" link || true
    echo ""
  fi
} >>"$LOG" 2>&1

log "=== DNS + CONNECTIVITY SMOKE ==="
{
  ping -c3 -W1 1.1.1.1
  getent hosts google.com
} >>"$LOG" 2>&1 || log "WARNING: initial connectivity smoke had errors"

# ---- Ping soak ----
log "=== PING SOAK TEST (${DURATION_MIN} min) ==="
END=$(( $(date +%s) + DURATION_MIN*60 ))
FAILS=0
TOTAL=0

while [ "$(date +%s)" -lt "$END" ]; do
  TOTAL=$((TOTAL + 1))
  if ping -c1 -W1 1.1.1.1 >/dev/null 2>&1; then
    log "ping ok"
  else
    FAILS=$((FAILS + 1))
    log "ping FAIL (fails=${FAILS})"
    {
      echo "--- iw link ---"
      command -v iw >/dev/null 2>&1 && iw dev "$WIFI_IFACE" link || true
      echo "--- route ---"
      ip route || true
      echo "--- active conns ---"
      command -v nmcli >/dev/null 2>&1 && nmcli -t -f NAME,DEVICE connection show --active || true
    } >>"$LOG" 2>&1
  fi
  sleep "$PING_INTERVAL"
done
log "Ping soak complete. total=${TOTAL}, fails=${FAILS}"

# ---- Idle timeout test (no traffic from this script) ----
if [[ "$DO_IDLE_TEST" == "1" ]]; then
  log "=== IDLE TEST (sleep ${IDLE_MIN} min, then probe) ==="
  sleep $((IDLE_MIN * 60))
  {
    echo "--- post-idle iw link ---"
    command -v iw >/dev/null 2>&1 && iw dev "$WIFI_IFACE" link || true
    echo "--- post-idle ping ---"
    ping -c3 -W1 1.1.1.1 || true
    echo "--- post-idle dns ---"
    getent hosts google.com || true
  } >>"$LOG" 2>&1
  log "Idle test complete"
fi

# ---- HTTPS churn test ----
if [[ "$DO_CHURN_TEST" == "1" ]]; then
  log "=== LIGHT CHURN TEST (${CHURN_ROUNDS} curls) ==="
  if command -v curl >/dev/null 2>&1; then
    for i in $(seq 1 "$CHURN_ROUNDS"); do
      if curl -sS -m 8 https://example.com >/dev/null 2>&1; then
        log "churn ok i=${i}"
      else
        log "churn FAIL i=${i}"
      fi
      sleep "$CHURN_SLEEP"
    done
  else
    log "curl not installed; skipping churn test"
  fi
fi

# ---- Disruptive test: force a wifi bounce ----
if [[ "$DO_DISRUPTIVE" == "1" ]]; then
  log "=== DISRUPTIVE TEST: disconnect/reconnect ${WIFI_IFACE} ==="
  if command -v nmcli >/dev/null 2>&1 && ip link show "$WIFI_IFACE" >/dev/null 2>&1; then
    nmcli dev disconnect "$WIFI_IFACE" >/dev/null 2>&1 || true
    sleep "$DISRUPTIVE_DOWN_SECONDS"
    nmcli dev connect "$WIFI_IFACE" >/dev/null 2>&1 || true
    sleep 5
    {
      echo "--- post-disrupt iw link ---"
      command -v iw >/dev/null 2>&1 && iw dev "$WIFI_IFACE" link || true
      echo "--- post-disrupt ping ---"
      ping -c3 -W1 1.1.1.1 || true
    } >>"$LOG" 2>&1
  else
    log "nmcli not available or ${WIFI_IFACE} missing; skipping disruptive test"
  fi
fi

# ---- API probe (prefers health_endpoint=/health if present) ----
if [[ "$DO_API_PROBE" == "1" ]]; then
  if command -v curl >/dev/null 2>&1 && [[ -n "${api_base_url:-}" ]] && [[ -n "${API_KEY:-}" ]]; then
    EP="${health_endpoint:-${ingest_endpoint:-}}"
    if [[ -z "$EP" ]]; then
      log "API probe skipped (no health_endpoint or ingest_endpoint in env.edge)"
    else
      URL="${api_base_url%/}${EP}"
      log "=== API PROBE (${API_METHOD} ${API_ROUNDS} rounds @ ${API_INTERVAL}s) -> ${URL} ==="

      for i in $(seq 1 "$API_ROUNDS"); do
        start_ms="$(date +%s%3N 2>/dev/null || echo 0)"

        if [[ "${API_METHOD}" == "POST" ]]; then
          payload="$(printf '{"ts":"%s","host":"%s","probe":"net_test","i":%d}' "$(date -Is)" "$(hostname)" "$i")"
          code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' \
            -X POST "$URL" \
            -H "Authorization: Bearer ${API_KEY}" \
            -H "Content-Type: application/json" \
            --data "$payload" || true)"
        else
          code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' \
            -X GET "$URL" \
            -H "Authorization: Bearer ${API_KEY}" || true)"
        fi

        end_ms="$(date +%s%3N 2>/dev/null || echo 0)"
        if [[ "$start_ms" != "0" && "$end_ms" != "0" ]]; then
          ms=$((end_ms - start_ms))
          log "api i=${i} http=${code} ms=${ms}"
        else
          log "api i=${i} http=${code}"
        fi

        sleep "$API_INTERVAL"
      done
    fi
  else
    log "API probe skipped (missing curl or api_base_url/API_KEY)"
  fi
fi

# ---- Modbus TCP probe (TCP connect only; no register reads) ----
if [[ "$DO_MODBUS_PROBE" == "1" ]]; then
  if command -v nc >/dev/null 2>&1 && [[ -n "${MODBUS_IP:-}" ]]; then
    PORT="${MODBUS_PORT:-502}"
    log "=== MODBUS TCP PROBE (${MODBUS_ROUNDS} rounds @ ${MODBUS_INTERVAL}s) -> ${MODBUS_IP}:${PORT} ==="
    for i in $(seq 1 "$MODBUS_ROUNDS"); do
      if nc -z -w2 "${MODBUS_IP}" "${PORT}" >/dev/null 2>&1; then
        log "modbus tcp ok i=${i}"
      else
        log "modbus tcp FAIL i=${i}"
      fi
      sleep "$MODBUS_INTERVAL"
    done
  else
    log "Modbus probe skipped (missing nc or MODBUS_IP)"
  fi
fi

# ---- Grab recent logs ----
log "=== RECENT LOGS (NetworkManager + watchdog if present) ==="
if command -v journalctl >/dev/null 2>&1; then
  {
    echo "--- NetworkManager (last 200 lines) ---"
    journalctl -u NetworkManager -n 200 --no-pager || true
    echo ""
    echo "--- consus-net-watchdog (last 200 lines) ---"
    journalctl -u consus-net-watchdog.service -n 200 --no-pager || true
  } >>"$LOG" 2>&1
else
  log "journalctl not available; skipping log capture"
fi

log "Done. Log written to: $LOG"
echo "$LOG"
