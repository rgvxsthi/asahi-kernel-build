# Post-reboot test checklist

Built 2026-07-25 on MacBook Pro 14" M1 Pro (`apple,j314s`).

Boot: reboot, then pick the GRUB entry containing **`-hdmifix`** (or whatever you set `LOCALVERSION` to).
Rollback at any time: reboot and pick a stock `*.asahi.fc44.aarch64+16k` entry. Stock kernels are untouched.

## 1. Right kernel booted

```bash
uname -r
```
Expect the kernel version of the branch you built, suffixed with `-hdmifix+`.

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

---

## Results — 2026-07-25, MacBook Pro 14" M1 Pro (`apple,j314s`), fairydust 7.0.13

| Test | Result |
|---|---|
| Correct kernel booted | Pass |
| GPU acceleration | Pass — `Apple M1 Pro (G13S C0)`, Mesa 26.1.5, not llvmpipe |
| HDMI connected across suspend | Pass — returns automatically, no replug |
| Resume with HDMI unplugged, plug in after | Pass — no regression, hotplug still works |
| Unplug HDMI while suspended | Pass — reports disconnected cleanly |
| Repeated suspend cycles | Pass — three cycles, all correct |
| Swap after reboot | Pass — `/dev/loop0`, 24G |
| BORE | Pass — `sched_bore=1` |

Both branches of `dcp_enable_dp2hdmi_hpd()` are exercised by these tests.

Display present on resume:

```
dcp_dptx_disconnect(port=0)
dcp_enable_dp2hdmi_hpd: DP2HDMI HPD connected:1
dcp_dptx_connect(port=0)
```

No display on resume — takes the `_dcp_poweroff()` path, and a later hotplug
still works, which was the main regression risk in this change:

```
dcp_dptx_disconnect(port=0)
dcp_enable_dp2hdmi_hpd: DP2HDMI HPD connected:0
dcp_poweroff() done
...
DP2HDMI HPD irq, connected:1
dcp_dptx_connect(port=0)
```

### Not yet tested

- Lid close/open as the suspend trigger, as opposed to `systemctl suspend`
- Long (overnight) suspend

### Pre-existing noise, unrelated to this patch

Present on the stock kernel too, verified before patching:

- `brcmf_p2p_*` wifi errors on every resume
- `apple-pmgr-pwrstate ... PS gfx: Failed to reach power state`
- `IOAVVideoInterface open failed` from the internal panel's DCP

Seen after patching but not verified against a pre-patch log, so noted rather
than dismissed. Both are DCP firmware messages during an otherwise successful
HDMI connect:

- `IOMFB updateFrequencies EDT ERROR: getClockFrequency(0) (0) < videoClock`
- `IOMFB read_pmu_data_sync: pmu ram read error (e00002d8)`
