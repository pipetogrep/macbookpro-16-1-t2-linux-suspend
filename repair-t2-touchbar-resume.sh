#!/bin/bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

backup_dir="/var/tmp/t2-touchbar-fix-backup-$(date +%Y%m%d-%H%M%S)"
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

install -d /usr/local/libexec

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

retoggle_touchbar_usb() {
  local dev=/sys/bus/usb/devices/7-6/bConfigurationValue
  [[ -w "${dev}" ]] || return 1
  echo 0 >"${dev}" 2>/dev/null || true
  sleep 1
  echo 2 >"${dev}" 2>/dev/null || true
}

reload_touchbar_stack() {
  systemctl stop tiny-dfr.service 2>/dev/null || true
  systemctl reset-failed dev-tiny_dfr_display.device dev-tiny_dfr_backlight.device dev-tiny_dfr_display_backlight.device tiny-dfr.service 2>/dev/null || true
  modprobe -r hid_appletb_kbd appletbdrm hid_appletb_bl 2>/dev/null || true
  udevadm settle -t 2 || true
  modprobe hid_appletb_bl 2>/dev/null || true
  sleep 1
  modprobe hid_appletb_kbd 2>/dev/null || true
  sleep 1
  modprobe appletbdrm 2>/dev/null || true
}

trigger_touchbar_udev() {
  udevadm trigger --subsystem-match=drm --action=change 2>/dev/null || true
  udevadm trigger --subsystem-match=backlight --action=change 2>/dev/null || true
  udevadm trigger --subsystem-match=input --action=change 2>/dev/null || true
  udevadm settle -t 10 || true
}

start_tiny_dfr_when_ready() {
  systemctl stop tiny-dfr.service 2>/dev/null || true
  systemctl reset-failed dev-tiny_dfr_display.device dev-tiny_dfr_backlight.device dev-tiny_dfr_display_backlight.device tiny-dfr.service 2>/dev/null || true
  if ! wait_for_units_active 6 \
    dev-tiny_dfr_display.device \
    dev-tiny_dfr_backlight.device \
    dev-tiny_dfr_display_backlight.device; then
    return 1
  fi
  systemctl start tiny-dfr.service 2>/dev/null || return 1
  sleep 1
  systemctl is-active --quiet tiny-dfr.service
}

log "resume worker: reloading BCE/Wi-Fi and repairing touch bar"
sleep 4
modprobe apple-bce 2>/dev/null || true
modprobe brcmfmac 2>/dev/null || true
modprobe brcmfmac_wcc 2>/dev/null || true
udevadm settle -t 10 || true

for attempt in 1 2 3 4; do
  log "resume worker: touch bar recovery attempt ${attempt}"
  retoggle_touchbar_usb || true
  wait_for_paths 12 \
    /sys/bus/usb/devices/7-6 \
    /sys/bus/usb/devices/7-6:2.0 \
    /sys/bus/usb/devices/7-6:2.1 \
    /sys/bus/usb/devices/7-7 \
    /sys/bus/usb/devices/7-7:1.0 || true
  sleep 2
  reload_touchbar_stack
  trigger_touchbar_udev

  # Restore touch bar backlight even if tiny-dfr still fails to come up.
  brightnessctl -d appletb_backlight s 2 >/dev/null 2>&1 || true

  if start_tiny_dfr_when_ready; then
    log "resume worker: touch bar restored"
    exit 0
  fi

  log "resume worker: touch bar still incomplete after attempt ${attempt}"
  sleep 2
done

log "resume worker: touch bar restore incomplete"
exit 0
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
    log "pre: stopping tiny-dfr and unloading BCE/Wi-Fi/touchbar stack"
    systemctl stop tiny-dfr.service 2>/dev/null || true
    modprobe -r hid_appletb_kbd appletbdrm hid_appletb_bl 2>/dev/null || true
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
TimeoutStopSec=10s
ExecStart=/usr/local/libexec/t2-suspend-helper.sh pre
ExecStop=/usr/local/libexec/t2-suspend-helper.sh post

[Install]
WantedBy=sleep.target
EOF_SERVICE

systemctl daemon-reload
systemctl enable suspend-fix-t2.service >/dev/null

# Best-effort current-boot touch bar recovery.
systemctl stop tiny-dfr.service 2>/dev/null || true
modprobe -r hid_appletb_kbd appletbdrm hid_appletb_bl 2>/dev/null || true
if [[ -w /sys/bus/usb/devices/7-6/bConfigurationValue ]]; then
  echo 0 >/sys/bus/usb/devices/7-6/bConfigurationValue 2>/dev/null || true
  sleep 1
  echo 2 >/sys/bus/usb/devices/7-6/bConfigurationValue 2>/dev/null || true
fi
sleep 2
modprobe hid_appletb_bl 2>/dev/null || true
sleep 1
modprobe hid_appletb_kbd 2>/dev/null || true
sleep 1
modprobe appletbdrm 2>/dev/null || true
udevadm trigger --subsystem-match=drm --action=change 2>/dev/null || true
udevadm trigger --subsystem-match=backlight --action=change 2>/dev/null || true
udevadm trigger --subsystem-match=input --action=change 2>/dev/null || true
udevadm settle -t 10 || true
brightnessctl -d appletb_backlight s 2 >/dev/null 2>&1 || true
systemctl reset-failed dev-tiny_dfr_display.device dev-tiny_dfr_backlight.device dev-tiny_dfr_display_backlight.device tiny-dfr.service 2>/dev/null || true
if systemctl is-active --quiet dev-tiny_dfr_display.device &&
   systemctl is-active --quiet dev-tiny_dfr_backlight.device &&
   systemctl is-active --quiet dev-tiny_dfr_display_backlight.device; then
  systemctl start tiny-dfr.service 2>/dev/null || true
fi

echo "Installed touch bar resume repair."
echo "Backup: ${backup_dir}"
echo
echo "Current service:"
systemctl status suspend-fix-t2.service --no-pager | sed -n '1,40p'
echo
echo "Current tiny-dfr status:"
systemctl status tiny-dfr.service --no-pager | sed -n '1,40p'
