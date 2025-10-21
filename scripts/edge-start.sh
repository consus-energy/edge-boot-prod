#!/usr/bin/env bash
set -Eeuo pipefail
ENV_FILE="${ENV_FILE:-/opt/edge-boot/env.edge}"
SERVICE_NAME="${SERVICE_NAME:-consus-edge}"

[ -f "$ENV_FILE" ] || { echo "[start] Missing $ENV_FILE"; exit 1; }
set -a; . "$ENV_FILE"; set +a

IMG="${EDGE_IMAGE:-europe-west2-docker.pkg.dev/consus-ems/consus-edge/edge-image:main}"

REG_MAP_MOUNT=()
if [[ -f /opt/edge-boot/register_map.json ]]; then
  REG_MAP_MOUNT=(-v /opt/edge-boot/register_map.json:/app/register_map.json:ro)
fi

echo "[start] Launching ${SERVICE_NAME} from ${IMG}"
docker rm -f "$SERVICE_NAME" >/dev/null 2>&1 || true
docker run -d \
  --name "$SERVICE_NAME" \
  --restart unless-stopped \
  --env-file "$ENV_FILE" \
  -e LOG_TO_STDOUT="${LOG_TO_STDOUT:-1}" \
  --network host \
  -v /opt/edge-boot/data/spool:/outbox \
  "${REG_MAP_MOUNT[@]}" \
  "$IMG"

echo "[start] Started. Logs: docker logs -f --tail 200 ${SERVICE_NAME}"
