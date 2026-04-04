#!/bin/bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

backup_dir="/var/tmp/t2-igpu-fix-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${backup_dir}"

backup_if_exists() {
  local path=$1
  if [[ -e "${path}" ]]; then
    cp -a "${path}" "${backup_dir}/"
  fi
}

backup_if_exists /etc/default/grub
backup_if_exists /etc/modprobe.d/apple-gmux.conf

install -d /etc/modprobe.d
cat >/etc/modprobe.d/apple-gmux.conf <<'EOF_GMUX'
# Use the integrated GPU as the default display adapter on hybrid T2 MacBook Pros.
options apple-gmux force_igd=y
EOF_GMUX

if [[ ! -f /etc/default/grub ]]; then
  echo "/etc/default/grub is missing; update your active bootloader config manually." >&2
  exit 1
fi

if grep -q 'i915.enable_guc=' /etc/default/grub; then
  sed -Ei 's/i915\.enable_guc=[^ "]+/i915.enable_guc=3/g' /etc/default/grub
else
  sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT="/ s/"$/ i915.enable_guc=3"/' /etc/default/grub
fi

mkinitcpio -P
grub-mkconfig -o /boot/grub/grub.cfg

echo
echo "Applied T2 iGPU-first resume workaround."
echo "Backup: ${backup_dir}"
echo
echo "Current GRUB line:"
grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub || true
echo
echo "apple-gmux config:"
cat /etc/modprobe.d/apple-gmux.conf
echo
echo "Reboot to test lid-close suspend again."
