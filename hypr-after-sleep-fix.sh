#!/bin/bash
set -euo pipefail

state_file="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-kbd-backlight"

restore_kbd_backlight() {
  local level
  local attempt

  if [[ -f "${state_file}" ]]; then
    level="$(tr -dc '0-9' <"${state_file}")"
  fi

  for attempt in 1 2 3 4 5 6 7 8; do
    if brightnessctl -m -d ':white:kbd_backlight' >/dev/null 2>&1; then
      if [[ -n "${level:-}" ]]; then
        brightnessctl -d ':white:kbd_backlight' set "${level}" >/dev/null 2>&1 || true
      fi
      return 0
    fi
    sleep 1
  done

  return 1
}

# Let Hyprland finish rebuilding outputs, then force the panel through a DPMS
# cycle and keep the ghost amdgpu connector disabled.
sleep 3
hyprctl keyword monitor "eDP-2, disable" >/dev/null 2>&1 || true
hyprctl dispatch dpms off >/dev/null 2>&1 || true
sleep 1
hyprctl dispatch dpms on >/dev/null 2>&1 || true
brightnessctl -r >/dev/null 2>&1 || true
restore_kbd_backlight || true
