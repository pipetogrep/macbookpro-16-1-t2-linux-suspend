# NAME

`macbook-16-1-t2-suspend-fix` - suspend, resume, Touch Bar, and backlight recovery helpers for T2 Macs running Omarchy on Arch Linux

# SYNOPSIS

Apply the base suspend fix:

```bash
sudo bash ./apply-t2-mac-sleep-fix.sh
sudo reboot
```

On hybrid Intel/AMD models such as `MacBookPro16,1`, optionally apply the iGPU-first resume workaround:

```bash
sudo bash ./apply-t2-igpu-resume-fix.sh
sudo reboot
```

Install the Hyprland user-session hooks:

```bash
install -Dm755 ./hypr-before-sleep-fix.sh ~/.local/bin/hypr-before-sleep-fix.sh
install -Dm755 ./hypr-after-sleep-fix.sh ~/.local/bin/hypr-after-sleep-fix.sh
systemctl --user enable --now hypridle.service
```

If the Touch Bar still fails after resume:

```bash
sudo bash ./repair-t2-touchbar-resume.sh
```

Optional log cleanup:

```bash
sudo bash ./install-t2-touchbar-log-cleanup.sh
```

# DESCRIPTION

This repository packages a working suspend and resume setup for T2 Macs using:

- Omarchy / Arch Linux
- `linux-t2`
- Hyprland + `hypridle`
- `tiny-dfr` for the Touch Bar

The bundle was built and tested on:

- Model: 2019 16-inch MacBook Pro
- SMBIOS: `MacBookPro16,1`
- Bootloader: GRUB

The target problems are:

- lid close detected but no real suspend
- blank or half-restored display after wake
- internal keyboard or trackpad missing after wake
- keyboard backlight not restoring
- Touch Bar failing to re-enumerate after resume

# COMPONENTS

`apply-t2-mac-sleep-fix.sh`

- installs the base suspend/resume helper
- sets the kernel in the direction of `mem_sleep_default=deep`
- switches `pcie_ports=native` to `pcie_ports=compat`
- disables conflicting legacy sleep hooks
- disables `powertop.service`

`apply-t2-igpu-resume-fix.sh`

- adds the iGPU-first workaround for hybrid Intel/AMD T2 models
- relevant to `MacBookPro16,1`

`repair-t2-touchbar-resume.sh`

- installs a dedicated `t2-post-resume.service`
- adds retry logic for Touch Bar device re-enumeration
- waits for the required `tiny-dfr` device units before starting `tiny-dfr`
- disables older Touch Bar sleep hooks that race the service

`repair-t2-suspend-helper.sh`

- older helper repair kept for reference

`hypr-before-sleep-fix.sh`

- locks the session
- saves keyboard backlight state
- turns keyboard backlight off before suspend

`hypr-after-sleep-fix.sh`

- waits for resume to settle
- repairs the panel state in Hyprland
- restores keyboard backlight

`hypridle.conf.snippet`

- snippet to merge into `~/.config/hypr/hypridle.conf`

`install-t2-touchbar-log-cleanup.sh`

- optional cleanup for noisy Touch Bar backlight journal messages

# REQUIREMENTS

- GRUB
- a T2-capable kernel, typically `linux-t2`
- Omarchy's Hyprland stack
- `tiny-dfr` if the machine uses the Touch Bar

The Touch Bar logic in this repository is written around the `MacBookPro16,1` USB and device-unit layout. Other T2 Macs may require edits.

# INSTALL PROCEDURE

## 1. Base suspend/resume path

Run:

```bash
sudo bash ./apply-t2-mac-sleep-fix.sh
sudo reboot
```

This installs:

- `/usr/local/libexec/t2-suspend-helper.sh`
- `/usr/local/libexec/t2-post-resume.sh`
- `/etc/systemd/system/suspend-fix-t2.service`
- `/etc/systemd/system/t2-post-resume.service`

It also disables these conflicting legacy hooks if present:

- `/usr/lib/systemd/system-sleep/t2-fix`
- `/usr/lib/systemd/system-sleep/touchbar-fix`
- `/usr/lib/systemd/system-sleep/95-appletb-order`

## 2. Hybrid graphics workaround

On `MacBookPro16,1` and similar hybrid Intel/AMD models:

```bash
sudo bash ./apply-t2-igpu-resume-fix.sh
sudo reboot
```

This is the script that pushes the machine toward:

- `options apple-gmux force_igd=y`
- `i915.enable_guc=3`

Do not assume it belongs on every T2 Mac.

## 3. Hyprland user-session hooks

Install the helper scripts:

```bash
install -Dm755 ./hypr-before-sleep-fix.sh ~/.local/bin/hypr-before-sleep-fix.sh
install -Dm755 ./hypr-after-sleep-fix.sh ~/.local/bin/hypr-after-sleep-fix.sh
```

Merge `hypridle.conf.snippet` into:

```text
~/.config/hypr/hypridle.conf
```

Then enable or restart `hypridle`:

```bash
systemctl --user enable --now hypridle.service
systemctl --user restart hypridle.service
```

## 4. Touch Bar recovery

If suspend and resume work but the Touch Bar still comes back dead or half-alive:

```bash
sudo bash ./repair-t2-touchbar-resume.sh
```

This keeps the dedicated `t2-post-resume.service` path and disables the older `system-sleep` Touch Bar hooks again, so the machine does not run multiple competing Touch Bar recovery paths at once.

## 5. Optional log cleanup

If the system works but the journal fills with messages such as:

- `systemd-backlight@backlight:appletb_backlight.service is masked`

run:

```bash
sudo bash ./install-t2-touchbar-log-cleanup.sh
```

This is cosmetic only.

# OPERATING MODEL

The intended resume path is:

- `suspend-fix-t2.service`
- `t2-post-resume.service`

That is the primary design assumption of this repository.

The machine is less reliable if older `system-sleep` hooks are still executable in parallel. Those hooks can race the dedicated post-resume service and leave the Touch Bar or input stack only partially restored.

Also avoid adding ad-hoc udev `RUN+=` helpers for T2 Touch Bar or keyboard-backlight devices if those helpers call `udevadm settle`. Blocking the udev queue during resume can cause the post-resume service to time out.

# VERIFY

After installation, test at least two complete lid-close cycles.

Expected result:

- the machine enters real suspend
- the internal display comes back
- unlock works
- internal keyboard and trackpad work
- keyboard backlight restores
- the Touch Bar returns, if present

# DIAGNOSTICS

General suspend/resume:

```bash
journalctl -b --no-pager | rg "PM: suspend|Lid closed|Lid opened|Apple Internal Keyboard|t2-post-resume|tiny_dfr|amdgpu"
```

Touch Bar specific:

```bash
journalctl -b -t t2-post-resume --no-pager
systemctl status dev-tiny_dfr_display.device tiny-dfr.service --no-pager
```

Current kernel command line:

```bash
cat /proc/cmdline
```

Hyprland idle hook status:

```bash
systemctl --user status hypridle.service --no-pager
```

The post-resume helper writes a compact summary into the journal after wake, including:

- suspend entered
- suspend exited
- time asleep
- power source before and after
- battery delta
- estimated sleep drain
- matched error lines
- unique issue buckets

# BATTERY-DRAIN TESTING

The post-resume helper snapshots battery state before suspend and after wake.

For meaningful suspend drain numbers:

- test on battery
- prefer 30 to 60 minute tests over 60 to 90 second lid-close tests
- run several cycles
- do one longer overnight run if you care about parasitic drain

Short tests are still useful for functional verification, but they are poor measurements.

# KNOWN GOOD DIRECTION FOR `MacBookPro16,1`

The configuration direction that worked on the test machine was:

- `mem_sleep_default=deep`
- `pcie_ports=compat`
- `apple-bce` unload/reload around suspend
- iGPU-first via `apple-gmux`
- Hyprland post-resume panel recovery
- explicit keyboard backlight save/restore
- Touch Bar recovery through `t2-post-resume.service`

# EXPECTED NOISE

The following messages may still appear even when the machine wakes successfully:

- `amdgpu ... Adding stream ... failed with err 28`
- `amdgpu ... Cannot find any crtc or sizes`
- `hid-appletb-bl ... usb_submit_urb(ctrl) failed: -1`

The practical question is not whether the journal is perfectly quiet. The practical question is whether:

- input devices return
- the display recovers
- unlock works
- `tiny-dfr` has live device units to bind to

# CAVEATS

- This repository is tuned around a 2019 16-inch T2 MacBook Pro.
- Other T2 Macs may need different graphics and Touch Bar handling.
- The Touch Bar logic is the most model-specific part of the bundle.
- The hybrid graphics workaround is not universal.
- This setup is materially better than stock suspend on this machine, but it is not macOS-grade.

# REFERENCES

Relevant upstream material:

- [t2linux State](https://wiki.t2linux.org/state/)
- [t2linux Post-Install Guide](https://wiki.t2linux.org/guides/postinstall/)
- [t2linux Hybrid Graphics Guide](https://wiki.t2linux.org/guides/hybrid-graphics/)
- [Omarchy Issue #1840](https://github.com/basecamp/omarchy/issues/1840)
- [t2linux/apple-bce-drv](https://github.com/t2linux/apple-bce-drv)
- [AsahiLinux/tiny-dfr](https://github.com/AsahiLinux/tiny-dfr)

# REUSE

If you apply this to another T2 Omarchy machine:

1. Start with the base script.
2. Only add the iGPU script on hybrid Intel/AMD hardware.
3. Install the Hyprland hooks.
4. Only add the Touch Bar repair if the stock path still fails.
5. Treat the log cleanup script as optional.
