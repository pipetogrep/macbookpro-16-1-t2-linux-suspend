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

log_summary_row() {
  local row
  printf -v row '| %-20s | %-25s |' "$1" "$2"
  log "$row"
}

format_ratio_pct() {
  awk -v n="$1" -v f="$2" 'BEGIN { if (f > 0) printf "%.2f", (100 * n) / f; else printf "n/a"; }'
}

detect_ac_online() {
  local ac
  for ac in /sys/class/power_supply/ADP* /sys/class/power_supply/AC*; do
    [[ -f "${ac}/online" ]] || continue
    cat "${ac}/online"
    return 0
  done
  return 1
}

log_battery_summary() {
  local slept_seconds=$1
  local state_dir=/run/t2-suspend-helper
  local bat_path ac_before_raw ac_after_raw before_src after_src
  local before_now before_full after_now after_full before_pct after_pct
  local delta_u delta_text rate_text

  [[ -d "${state_dir}" ]] || return 0
  bat_path="$(cat "${state_dir}/battery_path" 2>/dev/null || true)"
  if [[ -z "${bat_path}" || ! -d "${bat_path}" ]]; then
    for bat_path in /sys/class/power_supply/BAT*; do
      [[ -d "${bat_path}" ]] && break
    done
  fi
  [[ -n "${bat_path}" && -d "${bat_path}" ]] || return 0

  ac_before_raw="$(cat "${state_dir}/ac_online" 2>/dev/null || true)"
  ac_after_raw="$(detect_ac_online 2>/dev/null || true)"
  [[ -n "${ac_before_raw}" ]] && before_src="$([[ "${ac_before_raw}" == "1" ]] && echo AC || echo Battery)"
  [[ -n "${ac_after_raw}" ]] && after_src="$([[ "${ac_after_raw}" == "1" ]] && echo AC || echo Battery)"

  if [[ -f "${state_dir}/charge_now" && -f "${state_dir}/charge_full" && -f "${bat_path}/charge_now" && -f "${bat_path}/charge_full" ]]; then
    before_now="$(cat "${state_dir}/charge_now")"
    before_full="$(cat "${state_dir}/charge_full")"
    after_now="$(cat "${bat_path}/charge_now")"
    after_full="$(cat "${bat_path}/charge_full")"
    before_pct="$(format_ratio_pct "${before_now}" "${before_full}")"
    after_pct="$(format_ratio_pct "${after_now}" "${after_full}")"
    delta_u=$((before_now - after_now))
    delta_text="$(awk -v d="${delta_u}" 'BEGIN { printf "%.2f mAh", d / 1000.0 }')"
    rate_text="$(awk -v d="${delta_u}" -v s="${slept_seconds}" 'BEGIN { if (s > 0) printf "%.2f mA", (d / 1000.0) / (s / 3600.0); else printf "n/a"; }')"
  elif [[ -f "${state_dir}/energy_now" && -f "${state_dir}/energy_full" && -f "${bat_path}/energy_now" && -f "${bat_path}/energy_full" ]]; then
    before_now="$(cat "${state_dir}/energy_now")"
    before_full="$(cat "${state_dir}/energy_full")"
    after_now="$(cat "${bat_path}/energy_now")"
    after_full="$(cat "${bat_path}/energy_full")"
    before_pct="$(format_ratio_pct "${before_now}" "${before_full}")"
    after_pct="$(format_ratio_pct "${after_now}" "${after_full}")"
    delta_u=$((before_now - after_now))
    delta_text="$(awk -v d="${delta_u}" 'BEGIN { printf "%.2f mWh", d / 1000.0 }')"
    rate_text="$(awk -v d="${delta_u}" -v s="${slept_seconds}" 'BEGIN { if (s > 0) printf "%.2f mW", (d / 1000.0) / (s / 3600.0); else printf "n/a"; }')"
  else
    return 0
  fi

  if [[ -n "${before_src:-}" || -n "${after_src:-}" ]]; then
    log_summary_row "power source" "${before_src:-?} -> ${after_src:-?}"
  fi
  log_summary_row "battery before" "${before_pct}%"
  log_summary_row "battery after" "${after_pct}%"
  log_summary_row "battery delta" "${delta_text}"
  log_summary_row "est sleep drain" "${rate_text}"
}

log_last_sleep_summary() {
  local entry_raw exit_raw now_sec entry_sec exit_sec
  local start_iso exit_iso slept_seconds slept_text
  local error_matches raw_error_count error_buckets unique_error_count bucket_line
  local n=0

  entry_raw="$(journalctl -b --no-pager -o short-unix | awk '/PM: suspend entry/ {ts=$1} END{print ts}')"
  exit_raw="$(journalctl -b --no-pager -o short-unix | awk '/PM: suspend exit/ {ts=$1} END{print ts}')"
  [[ -n "${entry_raw}" && -n "${exit_raw}" ]] || return 0

  entry_sec="${entry_raw%%.*}"
  exit_sec="${exit_raw%%.*}"
  [[ "${entry_sec}" =~ ^[0-9]+$ && "${exit_sec}" =~ ^[0-9]+$ ]] || return 0
  (( exit_sec >= entry_sec )) || return 0

  now_sec="$(date +%s)"
  start_iso="$(date --iso-8601=seconds -d "@${entry_sec}" 2>/dev/null || date -d "@${entry_sec}" '+%Y-%m-%dT%H:%M:%S%z')"
  exit_iso="$(date --iso-8601=seconds -d "@${exit_sec}" 2>/dev/null || date -d "@${exit_sec}" '+%Y-%m-%dT%H:%M:%S%z')"
  slept_seconds=$((exit_sec - entry_sec))
  printf -v slept_text '%02d:%02d:%02d' $((slept_seconds / 3600)) $(((slept_seconds % 3600) / 60)) $((slept_seconds % 60))

  error_matches="$(journalctl -b --no-pager -o short-iso --since "@${entry_sec}" --until "@${now_sec}" | rg -i '(\*ERROR\*|(^|[[:space:]])error([[:space:]:]|$)| failed| failure|timed out|timeout)' | rg -v 'systemd-backlight@backlight:appletb_backlight.service is masked|Direct firmware load for brcm/brcmfmac4364b3-pcie\.apple,bali|hid_sensor_rotation .*failed to setup common attributes|hid_sensor_rotation .*probe with driver hid_sensor_rotation failed with error -22' || true)"
  raw_error_count="$(printf '%s\n' "${error_matches}" | sed '/^$/d' | wc -l | tr -d ' ')"
  error_buckets="$(printf '%s\n' "${error_matches}" | sed '/^$/d' | sed -E \
    -e 's/^[0-9T:+-]+ [^ ]+ [^:]+: //' \
    -e 's/[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]/PCI/gI' \
    -e 's/0x[0-9a-f]+/0xHEX/gI' \
    -e 's/Adding stream [0-9A-Fa-f]+ to context failed/Adding stream <id> to context failed/g' \
    -e 's/0003:05AC:[0-9A-Fa-f]+\.[0-9A-Fa-f]+/HIDID/g' \
    -e 's/HID-SENSOR-[0-9A-Fa-f.]+/HID-SENSOR/g' \
    -e 's/usb[0-9]+/usbN/g' \
    | sort | uniq -c | sort -nr || true)"
  unique_error_count="$(printf '%s\n' "${error_buckets}" | sed '/^$/d' | wc -l | tr -d ' ')"

  log '+----------------------+---------------------------+'
  log_summary_row "suspend entered" "${start_iso}"
  log_summary_row "suspend exited" "${exit_iso}"
  log_summary_row "time asleep" "${slept_text}"
  log_battery_summary "${slept_seconds}"
  log_summary_row "matched log lines" "${raw_error_count}"
  log_summary_row "unique issue types" "${unique_error_count}"
  log '+----------------------+---------------------------+'

  while IFS= read -r bucket_line; do
    [[ -n "${bucket_line}" ]] || continue
    ((n += 1))
    log "summary issue ${n}: ${bucket_line# }"
    (( n >= 3 )) && break
  done <<< "${error_buckets}"
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
log_last_sleep_summary
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

state_dir=/run/t2-suspend-helper

snapshot_battery_state() {
  local bat=
  local ac=
  local f

  install -d -m 0755 "${state_dir}"
  printf '%s\n' "$(date +%s)" > "${state_dir}/pre_epoch"

  for bat in /sys/class/power_supply/BAT*; do
    [[ -d "${bat}" ]] && break
  done
  if [[ -n "${bat}" && -d "${bat}" ]]; then
    printf '%s\n' "${bat}" > "${state_dir}/battery_path"
    for f in status capacity energy_now energy_full charge_now charge_full voltage_now current_now power_now; do
      if [[ -f "${bat}/${f}" ]]; then
        cat "${bat}/${f}" > "${state_dir}/${f}"
      else
        rm -f "${state_dir}/${f}"
      fi
    done
  fi

  for ac in /sys/class/power_supply/ADP* /sys/class/power_supply/AC*; do
    [[ -f "${ac}/online" ]] && break
  done
  if [[ -n "${ac}" && -f "${ac}/online" ]]; then
    cat "${ac}/online" > "${state_dir}/ac_online"
  else
    rm -f "${state_dir}/ac_online"
  fi
}

case "${1:-}" in
  pre)
    log "pre: stopping tiny-dfr and unloading BCE/Wi-Fi"
    snapshot_battery_state
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

if [[ -e /usr/lib/systemd/system-sleep/95-appletb-order ]]; then
  chmod -x /usr/lib/systemd/system-sleep/95-appletb-order
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
ls -l /usr/lib/systemd/system-sleep/t2-fix /usr/lib/systemd/system-sleep/touchbar-fix /usr/lib/systemd/system-sleep/95-appletb-order 2>/dev/null || true
echo
echo "powertop.service:"
systemctl is-enabled powertop.service 2>/dev/null || true
echo
echo "Reboot to activate the new kernel command line."
