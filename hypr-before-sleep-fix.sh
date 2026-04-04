#!/bin/bash
set -euo pipefail

state_dir="${XDG_CACHE_HOME:-$HOME/.cache}"
state_file="${state_dir}/omarchy-kbd-backlight"
mkdir -p "${state_dir}"

loginctl lock-session >/dev/null 2>&1 || true
if current="$(brightnessctl -m -d ':white:kbd_backlight' 2>/dev/null | cut -d, -f3)"; then
  printf '%s\n' "${current}" >"${state_file}"
fi
brightnessctl -d ':white:kbd_backlight' set 0 >/dev/null 2>&1 || true
