#!/bin/bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

backup_dir="/var/tmp/t2-sleep-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${backup_dir}"

backup_if_exists() {
  local path=$1
  if [[ -e "${path}" ]]; then
    cp -a "${path}" "${backup_dir}/"
  fi
}

backup_if_exists /etc/default/grub
backup_if_exists /etc/systemd/system/suspend-fix-t2.service
backup_if_exists /etc/systemd/system/t2-post-resume.service
backup_if_exists /etc/systemd/system/powertop.service
backup_if_exists /usr/lib/systemd/system-sleep/t2-fix
backup_if_exists /usr/lib/systemd/system-sleep/touchbar-fix
backup_if_exists /usr/lib/systemd/system-sleep/95-appletb-order

install -d /usr/local/libexec
install -D -m 0755 /dev/stdin /usr/local/libexec/t2-post-resume.sh <<'EOF_POST'
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

install -D -m 0644 /dev/stdin /etc/systemd/system/t2-post-resume.service <<'EOF_POST_SERVICE'
[Unit]
Description=T2 Mac post-resume recovery
After=systemd-suspend.service

[Service]
Type=oneshot
TimeoutStartSec=45s
ExecStart=/usr/local/libexec/t2-post-resume.sh
EOF_POST_SERVICE

install -D -m 0755 /dev/stdin /usr/local/libexec/t2-suspend-helper.sh <<'EOF_HELPER'
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

install -D -m 0644 /dev/stdin /etc/systemd/system/suspend-fix-t2.service <<'EOF_SERVICE'
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

if [[ -e /usr/lib/systemd/system-sleep/t2-fix ]]; then
  chmod -x /usr/lib/systemd/system-sleep/t2-fix
fi

if [[ -e /usr/lib/systemd/system-sleep/touchbar-fix ]]; then
  chmod -x /usr/lib/systemd/system-sleep/touchbar-fix
fi

if [[ ! -f /etc/default/grub ]]; then
  echo "/etc/default/grub is missing; update the active bootloader config manually." >&2
  exit 1
fi

sed -i 's/pcie_ports=native/pcie_ports=compat/g' /etc/default/grub
sed -i 's/mem_sleep_default=s2idle/mem_sleep_default=deep/g' /etc/default/grub

if ! grep -Fq 'intel_iommu=on' /etc/default/grub; then
  sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT="/ s/"$/ intel_iommu=on"/' /etc/default/grub
fi

if ! grep -Fq 'iommu=pt' /etc/default/grub; then
  sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT="/ s/"$/ iommu=pt"/' /etc/default/grub
fi

if ! grep -Fq 'mem_sleep_default=deep' /etc/default/grub; then
  sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT="/ s/"$/ mem_sleep_default=deep"/' /etc/default/grub
fi

if ! grep -Fq 'pcie_ports=compat' /etc/default/grub; then
  sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT="/ s/"$/ pcie_ports=compat"/' /etc/default/grub
fi

systemctl daemon-reload
systemctl enable suspend-fix-t2.service
systemctl disable powertop.service 2>/dev/null || true
grub-mkconfig -o /boot/grub/grub.cfg

echo
echo "Applied T2 sleep fix."
echo "Backup: ${backup_dir}"
echo
echo "Current GRUB line:"
grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub || true
echo
echo "Current suspend helper:"
systemctl cat suspend-fix-t2.service
echo
echo "Disabled legacy hooks:"
ls -l /usr/lib/systemd/system-sleep/t2-fix /usr/lib/systemd/system-sleep/touchbar-fix 2>/dev/null || true
echo
echo "powertop.service:"
systemctl is-enabled powertop.service 2>/dev/null || true
echo
echo "Reboot to activate the new kernel command line."
