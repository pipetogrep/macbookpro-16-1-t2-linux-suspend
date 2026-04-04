#!/bin/bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

backup_dir="/var/tmp/t2-touchbar-log-cleanup-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${backup_dir}"

backup_if_exists() {
  local path=$1
  if [[ -e "${path}" ]]; then
    cp -a "${path}" "${backup_dir}/"
  fi
}

override="/etc/udev/rules.d/99-t2-touchbar-backlight-quiet.rules"
backup_if_exists "${override}"

install -d /etc/udev/rules.d
cat >"${override}" <<'EOF_RULE'
# Prevent systemd's generic backlight helper from attaching to the T2 Touch Bar
# backlight device. The Touch Bar stack manages this path itself, and if the
# corresponding systemd-backlight unit is masked systemd logs on every event.
SUBSYSTEM=="backlight", KERNEL=="appletb_backlight", ENV{SYSTEMD_WANTS}=""
EOF_RULE

udevadm control --reload

echo
echo "Installed Touch Bar backlight udev override."
echo "Backup: ${backup_dir}"
echo
echo "Override:"
cat "${override}"
echo
echo "This only suppresses the masked systemd-backlight queue attempts for"
echo "appletb_backlight. It does not change the suspend/resume path."
