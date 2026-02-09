#!/usr/bin/env bash
set -Eeuo pipefail

note(){ echo "[start] $*" >&2; }
err(){ echo "[start][ERROR] $*" >&2; exit 1; }

ENV_FILE="${ENV_FILE:-/opt/edge-boot/env/env.edge}"
SERVICE_NAME="${SERVICE_NAME:-consus-edge}"

# Docker command (no $USER under systemd)
DOCKER="docker"
command -v docker >/dev/null 2>&1 || DOCKER="sudo docker"
if [ "$(id -u)" -ne 0 ]; then
  id -nG 2>/dev/null | grep -q '\bdocker\b' || DOCKER="sudo docker"
fi

# ---------- Minimal disk cleanup (no extra files) ----------
disk_guard() {
  local free_mb
  free_mb="$(df -Pm / | awk 'NR==2{print $4}')"
  if [ "${free_mb:-0}" -ge 1024 ]; then
    note "Disk OK (${free_mb}MB free on /)."
    return 0
  fi

  note "Low disk (${free_mb}MB free on /). Clearing old logs + docker logs + prune…"

  # 1) journald (fast win, safe)
  if command -v journalctl >/dev/null 2>&1; then
    sudo journalctl --vacuum-size=200M >/dev/null 2>&1 || true
  fi

  # 2) truncate big docker json logs (biggest win in practice)
  if [ -d /var/lib/docker/containers ]; then
    sudo find /var/lib/docker/containers -name '*-json.log' -type f -size +50M -print \
      -exec sudo sh -c 'truncate -s 0 "$1"' _ {} \; >/dev/null 2>&1 || true
  fi

  # 3) delete rotated/compressed logs
  sudo find /var/log -type f \( -name "*.gz" -o -name "*.[0-9]" -o -name "*.1" \) -delete >/dev/null 2>&1 || true

  # 4) docker prune (best effort)
  $DOCKER system prune -a -f --volumes >/dev/null 2>&1 || true

  free_mb="$(df -Pm / | awk 'NR==2{print $4}')"
  note "After cleanup: ${free_mb}MB free on /"
}

[ -f "$ENV_FILE" ] || err "Missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

IMG="${EDGE_IMAGE:-europe-west2-docker.pkg.dev/consus-ems/consus-edge/edge-image:main}"

REG_MAP_MOUNT=()
if [[ -f /opt/edge-boot/register_map.json ]]; then
  REG_MAP_MOUNT=(-v /opt/edge-boot/register_map.json:/app/register_map.json:ro)
fi

note "Launching ${SERVICE_NAME} from ${IMG}"

# ---- Minimal anti-disk-fill: cleanup only when low ----
disk_guard

# Pull (best effort)
$DOCKER pull "$IMG" || note "WARNING: pull failed, using cached image"

# Replace container
$DOCKER rm -f "$SERVICE_NAME" >/dev/null 2>&1 || true

# Container-level log rotation (works even if daemon.json is wrong)
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
