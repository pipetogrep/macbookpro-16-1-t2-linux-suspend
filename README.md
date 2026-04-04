# T2 Mac Suspend Fix for Omarchy

This bundle documents a working suspend/wake setup for T2 Macs running Omarchy on Arch with the `linux-t2` kernel.

It was tested on:

- Model: 2019 16-inch MacBook Pro
- SMBIOS: `MacBookPro16,1`
- Distro: Omarchy / Arch Linux
- Kernel: `linux-t2`
- Bootloader: GRUB
- Session: Hyprland + `hypridle`

## What It Fixes

This setup was built to address the usual T2 suspend problems:

- lid close detected, but no real suspend
- wake to blank or half-dead display
- internal keyboard or trackpad not returning after wake
- keyboard backlight not restoring
- Touch Bar breaking after resume

## What This Bundle Contains

- `apply-t2-mac-sleep-fix.sh`
  - Base suspend/wake fix for T2 on Omarchy.
- `apply-t2-igpu-resume-fix.sh`
  - iGPU-first workaround for hybrid graphics models like `MacBookPro16,1`.
- `repair-t2-suspend-helper.sh`
  - Earlier helper repair. Kept for reference/history.
- `repair-t2-touchbar-resume.sh`
  - Final Touch Bar resume repair.
- `install-t2-touchbar-log-cleanup.sh`
  - Optional cleanup for noisy `systemd-backlight` log spam on Touch Bar backlight events.
- `hypr-before-sleep-fix.sh`
  - User-session hook to lock and save/disable keyboard backlight before suspend.
- `hypr-after-sleep-fix.sh`
  - User-session hook to recover the panel and restore keyboard backlight after resume.
- `hypridle.conf.snippet`
  - Snippet to merge into Omarchy's `hypridle` config.

## Assumptions

- You are using GRUB.
- You are running a T2-capable kernel, typically `linux-t2`.
- You are using Omarchy's Hyprland stack.
- The Touch Bar scripts are written around the 2019 16-inch MacBook Pro layout and may need adjustment on other T2 Macs.

## What The Scripts Change

The base setup does four main things:

1. Switches the kernel sleep path to `deep`.
2. Uses `pcie_ports=compat` instead of `pcie_ports=native`.
3. Installs a `systemd` suspend helper that unloads and reloads `apple-bce` around suspend.
4. Disables conflicting legacy suspend hooks and `powertop.service`.

The hybrid graphics script adds:

- `options apple-gmux force_igd=y`
- `i915.enable_guc=3`

The user-session hooks add:

- explicit keyboard backlight save/restore
- Hyprland panel recovery after resume

The Touch Bar repair adds:

- a dedicated `t2-post-resume.service`
- Touch Bar device re-enumeration and retry logic
- delayed `tiny-dfr` startup only after the required device units are back

## Install

Run the commands from inside this directory.

### 1. Apply the base suspend/wake fix

```bash
sudo bash ./apply-t2-mac-sleep-fix.sh
sudo reboot
```

### 2. On hybrid graphics models, apply the iGPU-first workaround

This step matters on the 2019 16-inch model and other T2 MacBook Pros with both Intel and AMD graphics.

```bash
sudo bash ./apply-t2-igpu-resume-fix.sh
sudo reboot
```

If your machine is not a hybrid Intel/AMD model, do not blindly apply this step.

### 3. Install the Hyprland sleep hooks

Copy the user-session hooks into place:

```bash
install -Dm755 ./hypr-before-sleep-fix.sh ~/.local/bin/hypr-before-sleep-fix.sh
install -Dm755 ./hypr-after-sleep-fix.sh ~/.local/bin/hypr-after-sleep-fix.sh
```

Then merge the contents of `hypridle.conf.snippet` into your `~/.config/hypr/hypridle.conf`.

At minimum, make sure `hypridle` runs:

```bash
systemctl --user enable --now hypridle.service
```

If it was already enabled, restart it:

```bash
systemctl --user restart hypridle.service
```

### 4. If Touch Bar still breaks after resume

Run the Touch Bar repair:

```bash
sudo bash ./repair-t2-touchbar-resume.sh
```

That script installs a dedicated post-resume recovery service and does a best-effort current-boot recovery too.

### 5. Optional: silence harmless Touch Bar backlight `systemd` log spam

If suspend/wake works but your journal fills with messages like:

- `systemd-backlight@backlight:appletb_backlight.service is masked`

run:

```bash
sudo bash ./install-t2-touchbar-log-cleanup.sh
```

This only suppresses the `systemd-backlight` queue attempt for `appletb_backlight`. It is not required for suspend to work.

## Omarchy / Hyprland Notes

The Hyprland side matters on this setup.

The two important user-session hooks are:

- `hypr-before-sleep-fix.sh`
  - locks the session
  - saves keyboard backlight state
  - turns keyboard backlight off before suspend
- `hypr-after-sleep-fix.sh`
  - waits for resume to settle
  - disables the ghost `eDP-2` output
  - cycles DPMS
  - restores keyboard backlight explicitly

Without those hooks, the machine can resume but still feel broken in practice.

## Verify

After setup, test at least two full lid-close cycles.

Expected result:

- close lid
- machine actually suspends
- open lid
- screen comes back
- unlock works
- keyboard and trackpad work
- keyboard backlight returns
- Touch Bar returns if your machine uses it

## Useful Debug Commands

### General suspend/wake

```bash
journalctl -b --no-pager | rg "PM: suspend|Lid closed|Lid opened|Apple Internal Keyboard|t2-post-resume|tiny_dfr|amdgpu"
```

### Touch Bar

```bash
journalctl -b -t t2-post-resume --no-pager
systemctl status dev-tiny_dfr_display.device tiny-dfr.service --no-pager
```

The updated post-resume helper also writes a small summary table here after wake,
including:

- suspend entered
- suspend exited
- time asleep
- power source
- battery before / after
- battery delta
- estimated sleep drain
- matched log lines
- unique issue types

## Measuring Suspend Battery Drain

Yes, you can use this setup to measure parasitic draw during suspend.

The post-resume helper snapshots battery state immediately before suspend and
again after wake, then logs the delta in the `t2-post-resume` summary table.

For useful numbers:

- test on battery, not on AC
- use a longer sleep window, not a 60-90 second lid-close
- run at least a few 30-60 minute tests
- for a stronger check, do one overnight suspend on battery

Short sleeps are still useful for functional testing, but they are too short to
say much about real parasitic drain because battery counters can quantize or
barely move.

### Current kernel command line

```bash
cat /proc/cmdline
```

### User-side Hyprland hook status

```bash
systemctl --user status hypridle.service --no-pager
```

## Known Good Direction For `MacBookPro16,1`

On this model, the working direction was:

- `mem_sleep_default=deep`
- `pcie_ports=compat`
- `apple-bce` unload/reload around suspend
- iGPU-first via `apple-gmux`
- Hyprland post-resume panel recovery
- explicit keyboard backlight save/restore
- Touch Bar recovery via `t2-post-resume.service`

## Noise You May Still See

Some logs are annoying without necessarily meaning the setup is broken.

Examples:

- `amdgpu ... Adding stream ... failed with err 28`
- `amdgpu ... Cannot find any crtc or sizes`
- `hid-appletb-bl ... usb_submit_urb(ctrl) failed: -1`

On hybrid T2 Macs, these can appear during resume even when the machine wakes successfully.

What usually matters more is whether:

- the internal keyboard comes back
- the display returns
- the machine unlocks
- the Touch Bar service has real device units to bind to

## Caveats

- This was built around a 2019 16-inch T2 MacBook Pro.
- Other T2 Macs may need different handling, especially around graphics and Touch Bar USB paths.
- The Touch Bar repair is the most model-specific part of this bundle.
- The iGPU-first workaround is for hybrid graphics models. Do not assume it belongs on every T2 Mac.

## Why This Worked Better Than Earlier Attempts

The key fix was moving post-resume recovery into a real `systemd` unit instead of launching a background worker from `ExecStop`.

That made the BCE input recovery survive the suspend/resume transaction reliably enough for:

- keyboard and trackpad to return
- Touch Bar recovery to happen after resume, not during service teardown

## Robustness

This is good enough to call a working T2 Linux suspend solution for Omarchy on
`MacBookPro16,1`, but I would not call it perfect or macOS-grade yet.

What is strong now:

- lid close reaches real suspend
- wake returns the internal display and input devices
- keyboard backlight is handled explicitly in user space
- Touch Bar recovery is materially better than the stock path
- the post-resume journal summary makes failures measurable

What is still weaker than a native macOS experience:

- the setup still relies on model-specific suspend helpers and recovery hooks
- hybrid graphics remains the least elegant part of the stack
- Touch Bar recovery is the most fragile path
- some resume-time kernel noise is still expected on T2 Linux

If you want to keep refining it, the right next step is not more blind tweaking.
It is measuring longer battery-backed suspends and then tuning against real
drain numbers and repeatable failure signatures.

## References

These links were the most relevant sources used to assemble this setup. All were checked and live on April 4, 2026.

- [t2linux State](https://wiki.t2linux.org/state/)
  - Best high-level status page for suspend, Touch Bar, hybrid graphics, and known T2 limitations.
- [t2linux Post-Install Guide](https://wiki.t2linux.org/guides/postinstall/)
  - The most relevant upstream suspend workaround reference, including `apple-bce` handling and Touch Bar / `tiny-dfr` notes.
- [t2linux Hybrid Graphics Guide](https://wiki.t2linux.org/guides/hybrid-graphics/)
  - Directly relevant for `MacBookPro16,1`, including `apple-gmux force_igd=y` and `i915.enable_guc=3` for black-screen resume issues.
- [Omarchy Issue #1840: lid/sleep/suspend on MacBook](https://github.com/basecamp/omarchy/issues/1840)
  - The most relevant Omarchy-specific suspend thread and a useful pointer for Hyprland-side sleep behavior.
- [t2linux/apple-bce-drv](https://github.com/t2linux/apple-bce-drv)
  - Core driver stack behind BCE/VHCI input devices on T2 Macs, including the keyboard/trackpad path that made resume recovery necessary.
- [AsahiLinux/tiny-dfr](https://github.com/AsahiLinux/tiny-dfr)
  - The daemon used for dynamic Touch Bar function row behavior on Linux.

## Sharing / Reuse

If you reuse this on another T2 Omarchy machine:

1. Start with the base script.
2. Only add the iGPU script if you are on a hybrid Intel/AMD model.
3. Install the Hyprland hooks.
4. Only add the Touch Bar repair if you actually need it.
5. Treat the log cleanup script as optional polish, not part of the core fix.
