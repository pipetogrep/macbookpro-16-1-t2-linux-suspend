#!/bin/bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

backup_dir="/var/tmp/t2-suspend-helper-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${backup_dir}"

backup_if_exists() {
  local path=$1
  if [[ -e "${path}" ]]; then
    cp -a "${path}" "${backup_dir}/"
  fi
}

backup_if_exists /usr/local/libexec/t2-suspend-helper.sh
backup_if_exists /usr/local/libexec/t2-post-resume.sh
backup_if_exists /etc/systemd/system/suspend-fix-t2.service
backup_if_exists /etc/systemd/system/t2-post-resume.service

cat >/usr/local/libexec/t2-post-resume.sh <<'EOF_POST'
#!/bin/bash
set -euo pipefail

log() {
  logger -t t2-post-resume "$*"
}

wait_for_paths() {
  local timeout=$1
  shift
  local elapsed=0
  local path
  local ready
  while (( elapsed < timeout )); do
    ready=1
    for path in "$@"; do
      if [[ ! -e "${path}" ]]; then
        ready=0
        break
      fi
    done
    if (( ready )); then
      return 0
    fi
    sleep 1
    ((elapsed += 1))
  done
  return 1
}

wait_for_units_active() {
  local timeout=$1
  shift
  local elapsed=0
  local unit
  local ready
  while (( elapsed < timeout )); do
    ready=1
    for unit in "$@"; do
      if ! systemctl is-active --quiet "${unit}"; then
        ready=0
        break
      fi
    done
    if (( ready )); then
      return 0
    fi
    sleep 1
    ((elapsed += 1))
  done
  return 1
}

log "resume worker: reloading BCE and touch bar stack"
sleep 4
modprobe apple-bce 2>/dev/null || true
udevadm settle -t 10 || true

modprobe hid_appletb_bl 2>/dev/null || true
sleep 1
modprobe hid_appletb_kbd 2>/dev/null || true
sleep 1
modprobe appletbdrm 2>/dev/null || true
modprobe brcmfmac 2>/dev/null || true
modprobe brcmfmac_wcc 2>/dev/null || true

if wait_for_paths 12 /sys/bus/usb/devices/7-6 /sys/bus/usb/devices/7-6:2.1 /sys/bus/usb/devices/7-7 /sys/bus/usb/devices/7-7:1.0 &&
   wait_for_units_active 8 dev-tiny_dfr_display.device dev-tiny_dfr_backlight.device dev-tiny_dfr_display_backlight.device; then
  systemctl start tiny-dfr.service 2>/dev/null || true
  log "resume worker: touch bar devices present, tiny-dfr started"
else
  log "resume worker: touch bar devices did not reappear within timeout"
fi
EOF_POST
chmod 0755 /usr/local/libexec/t2-post-resume.sh

cat >/etc/systemd/system/t2-post-resume.service <<'EOF_POST_SERVICE'
[Unit]
Description=T2 Mac post-resume recovery
After=systemd-suspend.service

[Service]
Type=oneshot
TimeoutStartSec=45s
ExecStart=/usr/local/libexec/t2-post-resume.sh
EOF_POST_SERVICE

cat >/usr/local/libexec/t2-suspend-helper.sh <<'EOF_HELPER'
#!/bin/bash
set -euo pipefail

log() {
  logger -t t2-suspend-helper "$*"
}

case "${1:-}" in
  pre)
    log "pre: stopping tiny-dfr and unloading BCE/Wi-Fi"
    systemctl stop tiny-dfr.service 2>/dev/null || true
    modprobe -r brcmfmac_wcc brcmfmac 2>/dev/null || true
    rmmod -f apple-bce 2>/dev/null || true
    log "pre: complete"
    ;;
  post)
    log "post: starting t2-post-resume.service"
    systemctl reset-failed t2-post-resume.service dev-tiny_dfr_display.device tiny-dfr.service 2>/dev/null || true
    if systemctl start --no-block t2-post-resume.service 2>/dev/null; then
      log "post: queued t2-post-resume.service"
    else
      log "post: failed to queue t2-post-resume.service"
    fi
    ;;
  *)
    echo "usage: $0 pre|post" >&2
    exit 2
    ;;
esac
EOF_HELPER
chmod 0755 /usr/local/libexec/t2-suspend-helper.sh

cat >/etc/systemd/system/suspend-fix-t2.service <<'EOF_SERVICE'
[Unit]
Description=T2 Mac suspend/resume helper
Before=sleep.target
StopWhenUnneeded=yes

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=20s
TimeoutStopSec=20s
ExecStart=/usr/local/libexec/t2-suspend-helper.sh pre
ExecStop=/usr/local/libexec/t2-suspend-helper.sh post

[Install]
WantedBy=sleep.target
EOF_SERVICE

systemctl daemon-reload
systemctl enable suspend-fix-t2.service >/dev/null

# Best effort cleanup of the currently stuck pre-suspend helper.
main_pid="$(systemctl show -p MainPID --value suspend-fix-t2.service 2>/dev/null || true)"
if [[ -n "${main_pid}" && "${main_pid}" != "0" ]]; then
  kill -9 "${main_pid}" 2>/dev/null || true
fi
pkill -9 -f 'modprobe -r hci_uart' 2>/dev/null || true

# Restore touch bar modules and daemon for the current boot.
modprobe apple-bce 2>/dev/null || true
modprobe appletbdrm 2>/dev/null || true
modprobe hid_appletb_bl 2>/dev/null || true
modprobe hid_appletb_kbd 2>/dev/null || true
systemctl start tiny-dfr.service 2>/dev/null || true

echo "Updated suspend helper to the minimal BCE/Wi-Fi path."
echo "Backup: ${backup_dir}"
echo "Touch Bar recovery was attempted for the current boot."
echo "Reboot once to clear any stuck D-state helper process before testing lid close again."
