#!/usr/bin/env bash
set -Eeuo pipefail

# ========================================
# Consus Edge Deployment Utility
# Can be run from anywhere (e.g., inside tools/).
# ========================================

# Usage:
# ./tools/deploy_edge.sh <TARGET> <ENV_FILE> <KEY_JSON> [REPO_ROOT] [--run-boot]

TARGET="${1:?need TARGET (tailscale host/ip)}"
ENV_FILE="${2:?need path to env.edge for this site}"
KEY_JSON="${3:?need path to key.json}"
REPO_ROOT="${4:-}"

# --- Auto-detect repo root (if not provided) ---
if [[ -z "$REPO_ROOT" ]]; then
  # Get the directory where this script lives, then go up one level
  SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
  REPO_ROOT="$(realpath "${SCRIPT_DIR}/..")"
fi

RUN_BOOT="${5:-}"

BOOT_SH="${REPO_ROOT}/scripts/boot-min.sh"
EDGE_START_SH="${REPO_ROOT}/scripts/edge-start.sh"
VERIFY_SH="${REPO_ROOT}/scripts/verify.sh"
UNIT_FILE="${REPO_ROOT}/systemd/edge-boot.service"
REGMAP="${REPO_ROOT}/env/register_map.json"   # replace if you have a site-specific map

REMOTE_BOOT_DIR="/opt/edge-boot"
REMOTE_ENV="${REMOTE_BOOT_DIR}/env.edge"
REMOTE_KEY="${REMOTE_BOOT_DIR}/secrets/key.json"
REMOTE_REGMAP="${REMOTE_BOOT_DIR}/register_map.json"
REMOTE_UNIT="/etc/systemd/system/edge-boot.service"

err(){ echo "[deploy][ERROR] $*" >&2; exit 1; }
note(){ echo "[deploy] $*"; }


# Preflight
[[ -f "$ENV_FILE" ]] || err "Missing ENV_FILE $ENV_FILE"
[[ -f "$KEY_JSON" ]] || err "Missing KEY_JSON $KEY_JSON"
[[ -f "$BOOT_SH" ]] || err "Missing $BOOT_SH"
[[ -f "$EDGE_START_SH" ]] || err "Missing $EDGE_START_SH"
[[ -f "$VERIFY_SH" ]] || err "Missing $VERIFY_SH"
[[ -f "$UNIT_FILE" ]] || err "Missing $UNIT_FILE"

# SSH reachability
ssh -o BatchMode=yes -o ConnectTimeout=5 "pi@${TARGET}" "echo ok" >/dev/null 2>&1 || \
  ssh -o ConnectTimeout=5 "pi@${TARGET}" "echo ok" >/dev/null 2>&1 || \
  err "Cannot SSH to ${TARGET}. Ensure Tailscale is up."

note "Preparing remote directories…"
ssh "pi@${TARGET}" "sudo mkdir -p ${REMOTE_BOOT_DIR}/secrets ${REMOTE_BOOT_DIR}/data/spool ${REMOTE_BOOT_DIR}/tools ${REMOTE_BOOT_DIR}/wifi && sudo chown -R \$USER:\$USER ${REMOTE_BOOT_DIR}"

stage_push(){
  local src="$1" dst="$2" mode="$3"
  [[ -f "$src" ]] || return 0
  local tmp="/tmp/.consus.$(basename "$dst").$$.tmp"
  scp -q "$src" "pi@${TARGET}:${tmp}"
  ssh "pi@${TARGET}" "sudo install -m ${mode} -o root -g root ${tmp} ${dst}; rm -f ${tmp}"
  note "Updated $(basename "$dst")"
}

note "Uploading env, key, scripts, unit…"
stage_push "$ENV_FILE"      "$REMOTE_ENV"   "0644"
stage_push "$KEY_JSON"      "$REMOTE_KEY"   "0600"
stage_push "$BOOT_SH"       "${REMOTE_BOOT_DIR}/boot-min.sh" "0755"
stage_push "$EDGE_START_SH" "${REMOTE_BOOT_DIR}/edge-start.sh" "0755"
stage_push "$VERIFY_SH"     "${REMOTE_BOOT_DIR}/verify.sh" "0755"
stage_push "$UNIT_FILE"     "$REMOTE_UNIT"  "0644"
[[ -f "$REGMAP" ]] && stage_push "$REGMAP" "$REMOTE_REGMAP" "0644" || true

note "Reloading systemd & enabling provisioning oneshot…"
ssh "pi@${TARGET}" "sudo systemctl daemon-reload && sudo systemctl enable edge-boot.service"

note "Ensuring runtime does NOT autostart…"
ssh "pi@${TARGET}" "sudo systemctl disable --now consus-edge.service 2>/dev/null || true"

if [[ "$RUN_BOOT" == "--run-boot" ]]; then
  note "Triggering provisioning now…"
  ssh "pi@${TARGET}" "sudo systemctl start edge-boot.service && sleep 2; sudo systemctl status edge-boot.service --no-pager -l | tail -n 40"
else
  note "Provisioning will run on next boot."
fi

note "Done. Next:
  ssh pi@${TARGET}
  /opt/edge-boot/verify.sh
  sudo /opt/edge-boot/edge-start.sh
"
