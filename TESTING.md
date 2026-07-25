# Post-reboot test checklist — 7.0.13-rgvx+

Built 2026-07-25 on MacBook Pro 14" M1 Pro (`apple,j314s`).

Boot: reboot, then pick the GRUB entry containing **`-rgvx`**.
Rollback at any time: reboot and pick a stock `*.asahi.fc44.aarch64+16k` entry. Stock kernels are untouched.

## 1. Right kernel booted

```bash
uname -r
```
Expect `7.0.13-rgvx+`.

## 2. GPU acceleration (check this before anything else)

```bash
glxinfo | grep "OpenGL renderer"
lsmod | grep asahi
```
Must **not** say `llvmpipe`. If it does, the Rust GPU driver did not load — reboot into stock and report. Everything will feel sluggish until this is right.

## 3. The actual fix: HDMI across suspend

```bash
# with the HDMI cable plugged in and the monitor on
cat /sys/class/drm/card2-HDMI-A-1/status    # connected
systemctl suspend
# wake the machine, then:
cat /sys/class/drm/card2-HDMI-A-1/status    # must still be: connected
```
Pass = display comes back with **no replug**.

If it fails, capture the evidence:
```bash
sudo dmesg | grep -iE "dcp|dptx|hpd" | tail -40
```
Look for `dcp_enable_dp2hdmi_hpd` and `dcp_dptx_connect(port=0)` after the resume. Absent means the patch did not take effect.

## 4. Swap survived the reboot

```bash
swapon --show
```
Expect `/dev/loop0`, 24G. Empty means the systemd ordering cycle is back:
```bash
systemctl status swapfile-loop.service     # look for "ordering cycle"
```

## 5. BORE active

```bash
cat /proc/sys/kernel/sched_bore            # 1
```
Disable without rebuilding if anything feels worse:
```bash
sudo sysctl kernel.sched_bore=0
```

## 6. Nothing else regressed

Quick sweep — wifi, bluetooth, audio, webcam, USB-C dock, battery percentage, external keyboard.

```bash
sudo dmesg --level=err,warn | tail -30
```

## Optional, unrelated to this build

USB-C DisplayPort alt mode (the original point of the fairydust branch) also ships in this kernel. Front-most USB-C port, closest to the trackpad. Only one port supports it.
