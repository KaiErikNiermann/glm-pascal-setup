#!/usr/bin/env bash
# Install the systemd --user unit so the server survives reboots.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_settings

need systemctl

UNIT_DIR="${HOME}/.config/systemd/user"
UNIT="${UNIT_DIR}/llama-glm.service"
mkdir -p "$UNIT_DIR" "${LLM_ROOT}/logs"

if [ -e "$UNIT" ]; then
  warn "$UNIT already exists"
  printf 'Overwrite it? [y/N] ' >&2
  read -r reply
  case "$reply" in [yY]*) ;; *) die "aborted -- nothing changed" ;; esac
fi

sed -e "s|@@REPO_ROOT@@|${REPO_ROOT}|g" \
    -e "s|@@LLM_ROOT@@|${LLM_ROOT}|g" \
    "${REPO_ROOT}/config/llama-glm.service.template" > "$UNIT"
ok "wrote $UNIT"

systemctl --user daemon-reload
systemctl --user enable --now llama-glm.service
ok "enabled and started"

# Without lingering, a --user unit stops when your last session ends and does not
# come back until you log in again.
if command -v loginctl >/dev/null 2>&1; then
  if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" = "yes" ]; then
    ok "lingering already enabled -- starts at boot without a login"
  else
    warn "lingering is OFF: the service will stop when you log out."
    warn "Enable it with:  sudo loginctl enable-linger $(id -un)"
  fi
fi

echo
log "Follow startup with:  journalctl --user -u llama-glm -f"
log "Or the log file:      tail -f ${LLM_ROOT}/logs/service.log"
