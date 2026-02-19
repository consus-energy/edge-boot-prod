#!/usr/bin/env bash
set -Eeuo pipefail

note(){ echo "[start] $*" >&2; }
err(){ echo "[start][ERROR] $*" >&2; exit 1; }

ENV_FILE="${ENV_FILE:-/opt/edge-boot/env/env.edge}"
SERVICE_NAME="${SERVICE_NAME:-consus-edge}"

DOCKER="docker"
command -v docker >/dev/null 2>&1 || DOCKER="sudo docker"
if [ "$(id -u)" -ne 0 ]; then
  id -nG 2>/dev/null | grep -q '\bdocker\b' || DOCKER="sudo docker"
fi

disk_guard() {
  local free_mb
  free_mb="$(df -Pm / | awk 'NR==2{print $4}')"
  if [ "${free_mb:-0}" -ge 1024 ]; then
    note "Disk OK (${free_mb}MB free on /)."
    return 0
  fi

  note "Low disk (${free_mb}MB free on /). Clearing old logs + docker logs + prune…"

  if command -v journalctl >/dev/null 2>&1; then
    sudo journalctl --vacuum-time=3d >/dev/null 2>&1 || true
    sudo journalctl --vacuum-size=200M >/dev/null 2>&1 || true
  fi

  if [ -d /var/lib/docker/containers ]; then
    sudo find /var/lib/docker/containers -name '*-json.log' -type f -size +50M -print \
      -exec sudo sh -c 'truncate -s 0 "$1"' _ {} \; >/dev/null 2>&1 || true
  fi

  sudo find /var/log -type f \( -name "*.gz" -o -name "*.[0-9]" -o -name "*.1" \) -delete >/dev/null 2>&1 || true

  $DOCKER system prune -a -f --volumes >/dev/null 2>&1 || true

  free_mb="$(df -Pm / | awk 'NR==2{print $4}')"
  note "After cleanup: ${free_mb}MB free on /"
}

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

[ -f "$ENV_FILE" ] || err "Missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

# --- guard-only mode: used by systemd timer ---
if [[ "${1:-}" == "--guard-once" ]]; then
  disk_guard || true
  health_guard || true
  exit 0
fi

IMG="${EDGE_IMAGE:-europe-west2-docker.pkg.dev/consus-ems/consus-edge/edge-image:main}"

REG_MAP_MOUNT=()
if [[ -f /opt/edge-boot/register_map.json ]]; then
  REG_MAP_MOUNT=(-v /opt/edge-boot/register_map.json:/app/register_map.json:ro)
fi

note "Launching ${SERVICE_NAME} from ${IMG}"

disk_guard
health_guard

$DOCKER pull "$IMG" || note "WARNING: pull failed, using cached image"
$DOCKER rm -f "$SERVICE_NAME" >/dev/null 2>&1 || true

$DOCKER run -d \
  --name "$SERVICE_NAME" \
  --restart unless-stopped \
  --env-file "$ENV_FILE" \
  -e LOG_TO_STDOUT="${LOG_TO_STDOUT:-1}" \
  --network host \
  -v /opt/edge-boot/data/spool:/outbox \
  "${REG_MAP_MOUNT[@]}" \
  --log-driver json-file \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  "$IMG"

note "Started. Logs: $DOCKER logs -f --tail 200 ${SERVICE_NAME}"
