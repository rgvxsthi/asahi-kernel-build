# asahi-linux-hdmi-sleep-fixer

**Fixes the built-in HDMI port staying dark after suspend on Apple Silicon Macs running Asahi Linux.**

If you suspend your Mac with a monitor plugged into the laptop's own HDMI port, wake it up, and the monitor stays black — and the only thing that brings it back is physically unplugging and replugging the cable — this repo fixes that. It builds a kernel with a two-line driver patch and installs it alongside your existing one.

It also enables USB-C DisplayPort alt mode, because it builds on Asahi's `fairydust` branch. That part is inherited, not the point of this fork.

> Fork of **[bharambetejas/asahi-fairydust-display](https://github.com/bharambetejas/asahi-fairydust-display)**, which does the actual heavy lifting of building an Asahi kernel correctly. See [Credits](#credits).

## Is this your bug?

Yes, if:

- Your Mac has a **physical HDMI port** (MacBook Pro 14"/16", Mac mini) with a monitor plugged into it
- The display works fine until you suspend
- After resume the internal panel is fine but the external is dead
- **Unplugging and replugging the HDMI cable fixes it, every time**
- `cat /sys/class/drm/card*-HDMI-A-1/status` says `disconnected` while the cable is clearly plugged in

No, if your monitor is on **USB-C / Thunderbolt**. That's a different code path with different problems.

**Note:** the `fairydust` branch on its own does **not** fix this. Its `dcp.c` is byte-identical to `asahi-wip`. fairydust adds USB-C DisplayPort alt mode, which is a separate output path from the built-in HDMI port. Trying fairydust for this bug is a dead end — that's what prompted this fork.

## What actually causes it

In `drivers/gpu/drm/apple/dcp.c`, suspend disables the hotplug interrupt and tears the DisplayPort link down:

```c
static int dcp_platform_suspend(struct device *dev)
{
	if (dcp->hdmi_hpd_irq) {
		disable_irq(dcp->hdmi_hpd_irq);
		disconnected_hpd_event(dcp->connector);
		dcp_dptx_disconnect(dcp, 0);
	}
}
```

Resume only turns the interrupt back on:

```c
static int dcp_platform_resume(struct device *dev)
{
	if (dcp->hdmi_hpd_irq)
		enable_irq(dcp->hdmi_hpd_irq);
}
```

That interrupt is **edge triggered** — the driver says so in its own comment. A display left plugged in across suspend generates no edge, so the handler never runs and `dcp_dptx_connect()` is never called again. Replugging the cable works because it manually produces the edge the driver is waiting for.

The driver already has the right helper: `dcp_enable_dp2hdmi_hpd()` samples the HPD GPIO, reconnects if a display is present, and *then* enables the interrupt. It is already used from `dcp_wait_ready()`. Resume simply was not calling it.

```diff
  	if (dcp->hdmi_hpd_irq)
- 		enable_irq(dcp->hdmi_hpd_irq);
+ 		dcp_enable_dp2hdmi_hpd(dcp);
```

That is the entire fix: [`patches/0001-drm-apple-reconnect-DP2HDMI-output-on-resume.patch`](patches/0001-drm-apple-reconnect-DP2HDMI-output-on-resume.patch).

## Requirements

- **Fedora Asahi Remix** on Apple Silicon
- **15 GB+ free disk space**
- **1.5–3 hours** for the build
- 16 GB RAM machines: pass `JOBS=6` or the build will thrash swap

## Usage

```bash
git clone https://github.com/rgvxsthi/asahi-linux-hdmi-sleep-fixer.git
cd asahi-linux-hdmi-sleep-fixer
./asahi-fairydust-build.sh
```

Reboot and pick the `-rgvx` entry in GRUB.

Unattended, on a 16 GB machine:

```bash
ASSUME_YES=1 NO_REBOOT=1 JOBS=6 ./asahi-fairydust-build.sh
```

### Verify it worked

```bash
uname -r                                      # 7.0.13-rgvx+
glxinfo | grep "OpenGL renderer"              # Apple M1 Pro (...), NOT llvmpipe
cat /sys/class/drm/card*-HDMI-A-1/status      # connected
systemctl suspend                             # wake it, then check again
cat /sys/class/drm/card*-HDMI-A-1/status      # still connected, no replug
```

On resume, `dmesg` should now show:

```
apple-dcp 289c00000.dcp: dcp_enable_dp2hdmi_hpd: DP2HDMI HPD connected:1
apple-dcp 289c00000.dcp: dcp_dptx_connect(port=0)
```

Full checklist in [TESTING.md](TESTING.md).

### Reverting

Your stock kernel is untouched and stays in GRUB — select it at boot. To remove the custom kernel entirely, boot into stock and run `./asahi-fairydust-uninstall.sh`.

## Configuration

Everything is environment-overridable:

| Variable | Default | Purpose |
|---|---|---|
| `REPO_URL` | `https://github.com/rgvxsthi/linux.git` | Kernel source |
| `BRANCH` | `rgvx/fairydust` | Branch to build |
| `CLONE_DIR` | `$HOME/linux-fairydust` | Where to clone |
| `LOCALVERSION` | `-rgvx` | Kernel name suffix / GRUB entry |
| `JOBS` | `$(nproc)` | Parallel build jobs |
| `ASSUME_YES` | `0` | Answer prompts automatically |
| `NO_REBOOT` | `0` | Never reboot, even unattended |
| `SKIP_PATCHES` | `0` | Build the branch unpatched |

## Patches

Everything in `patches/*.patch` is applied in filename order after cloning and before configuring. Already-applied patches are detected and skipped, so re-runs are safe. A patch that no longer applies is a hard error rather than a silent skip — if that happens, the change has probably landed upstream and the file can be deleted.

Drop your own `.patch` files in there and they will be picked up.

## What the script does

1. Installs build dependencies (gcc, Rust toolchain, etc.)
2. Clones the kernel branch
3. Applies `patches/`
4. Seeds the config from your currently running kernel
5. Enables Rust + the Asahi GPU driver (without this you land on llvmpipe and everything crawls)
6. Enables USB-C DisplayPort alt mode modules
7. Builds
8. Installs kernel, modules and device tree blobs
9. Updates m1n1 and GRUB
10. Sets up typec module autoloading

## Differences from upstream

Beyond the HDMI patch, this fork carries build fixes that have been offered back to the original repo:

- **`rust/core.o` build failure.** The kernel compiles the Rust core library from source, so `rustc` and `rust-src` must be the same version. A rustup toolchain in `~/.cargo/bin` shadows `/usr/bin/rustc` and is usually a different version from the `rust-src` package, producing `attributes starting with 'rustc' are reserved` and `cannot use 'const' closures outside of const contexts`. Now pinned to the distro toolchain.
- **`ASSUME_YES` / `NO_REBOOT`** for unattended builds, with reboot kept as a separate opt-in so an unattended run can never reboot on its own.
- **Environment-overridable config**, so you can build your own branch without editing the script.
- **Non-destructive clone step** — reuses an existing checkout instead of offering to delete it, and clones blobless rather than `--depth 1` so the tree stays rebaseable.
- **`sync-upstream.sh`** to rebase local patches onto a newer upstream branch.

## Caveats

- Custom kernel. **Module signing is disabled.**
- `dnf` will keep updating your stock kernel; this one stays until you rebuild.
- When upstream moves, run `./sync-upstream.sh` and rebuild.
- The `fairydust` branch is experimental and not officially supported by the Asahi team.

## Credits

This repository is a fork and stands almost entirely on other people's work.

- **[bharambetejas/asahi-fairydust-display](https://github.com/bharambetejas/asahi-fairydust-display)** by Tejas Bharambe — the original build script, and the reason any of this was approachable. It solves the genuinely hard parts: seeding the config from your running kernel, getting Rust and the GPU driver enabled so you do not end up on llvmpipe, and wiring up m1n1 and GRUB correctly. This fork adds a patch step and some build fixes on top; the generic improvements have been sent back upstream as pull requests.
- **[Asahi Linux team](https://asahilinux.org/)** (marcan, Sven Peter, Janne Grunau, and everyone else) for the kernel, the `fairydust` branch, and years of reverse engineering that made Linux on Apple Silicon exist at all. The fix here is two lines in a driver they wrote from scratch against undocumented hardware. Finding a gap in it is a very different thing from building it.
- **[r/AsahiLinux](https://www.reddit.com/r/AsahiLinux/)** and the wider Asahi community, whose bug reports and troubleshooting threads made this identifiable as a real reproducible issue rather than one broken machine.
- Build process follows the [Asahi progress report](https://asahilinux.org/2026/02/progress-report-6-19/).

Prior reports of the HDMI issue:
[Fedora discussion](https://discussion.fedoraproject.org/t/hdmi-output-after-suspend-to-ram-on-macbook-pro/101597),
[AsahiLinux/docs#94](https://github.com/AsahiLinux/docs/issues/94).

## Tested on

MacBook Pro 14-inch M1 Pro (`apple,j314s`), Fedora Asahi Remix 44, kernel 7.0.13.

Reports from other models welcome — particularly M1 Max, M2 Pro/Max and Mac mini, which have the same built-in HDMI path and should behave identically.

## License

MIT
