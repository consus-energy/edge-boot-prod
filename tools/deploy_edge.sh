#!/usr/bin/env bash
set -Eeuo pipefail

# ========================================
# Consus Edge Deployment Utility
# ========================================

TARGET_IN="${1:?need TARGET (host or user@host)}"
if [[ "$TARGET_IN" == *@* ]]; then
  TARGET="$TARGET_IN"
else
  TARGET="pi@${TARGET_IN}"
fi
RUN_BOOT="${2:-}"

# --- SSH connection sharing (enter password once) ---
CONTROL_PATH="/tmp/ssh-%r@%h:%p"
SSH_OPTS="-o ControlMaster=auto -o ControlPath=${CONTROL_PATH} -o ControlPersist=600 -o StrictHostKeyChecking=accept-new"
# Start master connection (will prompt once)
ssh ${SSH_OPTS} -Nf "${TARGET}" || true

# --- Auto-detect repo root ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$(realpath "${SCRIPT_DIR}/..")"

# --- Fixed local paths (baked-in) ---
ENV_FILE="${REPO_ROOT}/env/env.edge"
KEY_JSON="${REPO_ROOT}/secrets/key.json"
BOOT_SH="${REPO_ROOT}/scripts/boot-min.sh"
EDGE_START_SH="${REPO_ROOT}/scripts/edge-start.sh"
VERIFY_SH="${REPO_ROOT}/scripts/verify.sh"
UNIT_FILE="${REPO_ROOT}/systemd/edge-boot.service"
REGMAP="${REPO_ROOT}/env/register_map.json"
NET_DOG="${REPO_ROOT}/scripts/net_watchdog.sh"
NET_TEST="${REPO_ROOT}/scripts/net_test.sh"

# --- Fixed remote paths ---
REMOTE_BOOT_DIR="/opt/edge-boot"
REMOTE_ENV_DIR="${REMOTE_BOOT_DIR}/env"
REMOTE_ENV="${REMOTE_ENV_DIR}/env.edge"
REMOTE_KEY="${REMOTE_BOOT_DIR}/secrets/key.json"
REMOTE_REGMAP="${REMOTE_BOOT_DIR}/register_map.json"
REMOTE_UNIT="/etc/systemd/system/edge-boot.service"
REMOTE_NET_DOG="${REMOTE_BOOT_DIR}/scripts/net_watchdog.sh"
REMOTE_NET_TEST="${REMOTE_BOOT_DIR}/scripts/net_test.sh"

err(){ echo "[deploy][ERROR] $*" >&2; exit 1; }
note(){ echo "[deploy] $*"; }

# Preflight
[[ -f "$ENV_FILE" ]] || err "Missing $ENV_FILE"
[[ -f "$KEY_JSON" ]] || err "Missing $KEY_JSON"
[[ -f "$BOOT_SH" ]] || err "Missing $BOOT_SH"
[[ -f "$EDGE_START_SH" ]] || err "Missing $EDGE_START_SH"
[[ -f "$VERIFY_SH" ]] || err "Missing $VERIFY_SH"
[[ -f "$UNIT_FILE" ]] || err "Missing $UNIT_FILE"
[[ -f "$NET_DOG" ]] || err "Missing $NET_DOG"
[[ -f "$NET_TEST" ]] || err "Missing $NET_TEST"

note "Preparing remote directories…"
ssh ${SSH_OPTS} "${TARGET}" "\
  sudo mkdir -p \
    ${REMOTE_ENV_DIR} \
    ${REMOTE_BOOT_DIR}/secrets \
    ${REMOTE_BOOT_DIR}/data/spool \
    ${REMOTE_BOOT_DIR}/tools \
    ${REMOTE_BOOT_DIR}/wifi \
    ${REMOTE_BOOT_DIR}/scripts \
  && sudo chown -R \$USER:\$USER ${REMOTE_BOOT_DIR}
"

stage_push(){
  local src="$1" dst="$2" mode="$3"
  [[ -f "$src" ]] || return 0
  local tmp="/tmp/.consus.$(basename "$dst").$$.tmp"
  scp -q ${SSH_OPTS} "$src" "${TARGET}:${tmp}"
  ssh ${SSH_OPTS} "${TARGET}" "sudo install -m ${mode} -o root -g root ${tmp} ${dst}; rm -f ${tmp}"
  note "Updated $(basename "$dst")"
}

note "Uploading env, key, scripts, unit…"
stage_push "$ENV_FILE"      "$REMOTE_ENV"   "0644"
stage_push "$KEY_JSON"      "$REMOTE_KEY"   "0600"
stage_push "$BOOT_SH"       "${REMOTE_BOOT_DIR}/boot-min.sh" "0755"
stage_push "$EDGE_START_SH" "${REMOTE_BOOT_DIR}/edge-start.sh" "0755"
stage_push "$VERIFY_SH"     "${REMOTE_BOOT_DIR}/verify.sh" "0755"
stage_push "$NET_DOG"       "$REMOTE_NET_DOG" "0755"
stage_push "$NET_TEST"      "$REMOTE_NET_TEST" "0755"
stage_push "$UNIT_FILE"     "$REMOTE_UNIT"  "0644"
[[ -f "$REGMAP" ]] && stage_push "$REGMAP" "$REMOTE_REGMAP" "0644" || true

note "Reloading systemd & enabling provisioning oneshot…"
ssh ${SSH_OPTS} "${TARGET}" "sudo systemctl daemon-reload && sudo systemctl enable edge-boot.service"

note "Ensuring runtime does NOT autostart…"
ssh ${SSH_OPTS} "${TARGET}" "sudo systemctl disable --now consus-edge.service 2>/dev/null || true"

if [[ "$RUN_BOOT" == "--run-boot" ]]; then
  note "Triggering provisioning now…"
  ssh ${SSH_OPTS} "${TARGET}" "sudo systemctl start edge-boot.service && sleep 2; sudo systemctl status edge-boot.service --no-pager -l | tail -n 40"
else
  note "Provisioning will run on next boot."
fi

# Close master connection
ssh -O exit -o ControlPath="${CONTROL_PATH}" "${TARGET}" >/dev/null 2>&1 || true

note "Done. Next:
  ssh ${TARGET}
  /opt/edge-boot/verify.sh
  sudo /opt/edge-boot/edge-start.sh

Net test (optional):
  sudo /opt/edge-boot/scripts/net_test.sh /opt/edge-boot/data/spool/net-tests
"
