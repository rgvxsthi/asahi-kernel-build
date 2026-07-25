# asahi-linux-hdmi-sleep-fixer

**Fixes the built-in HDMI port staying dark after suspend on Apple Silicon Macs running Asahi Linux.**

If you suspend your Mac with a monitor plugged into the laptop's own HDMI port, wake it up, and the monitor stays black — and the only thing that brings it back is physically unplugging and replugging the cable — this repo fixes that. It builds a kernel with a two-line driver patch and installs it alongside your existing one.

It also enables USB-C DisplayPort alt mode, because it builds on Asahi's `fairydust` branch. That part is inherited, not the point of this fork.

> Fork of **[bharambetejas/asahi-fairydust-display](https://github.com/bharambetejas/asahi-fairydust-display)**, which does the actual heavy lifting of building an Asahi kernel correctly. See [Credits](#credits).

**Discussion:** [r/AsahiLinux thread](https://www.reddit.com/r/AsahiLinux/comments/1v65rk7/hdmi_wouldnt_wake_after_sleep_on_mbp_m1_pro/) — reports from other models welcome there.

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

Reboot and pick the `-hdmifix` entry in GRUB.

Unattended, on a 16 GB machine:

```bash
ASSUME_YES=1 NO_REBOOT=1 JOBS=6 ./asahi-fairydust-build.sh
```

### Verify it worked

```bash
uname -r                                      # e.g. 7.0.13-hdmifix+
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
| `REPO_URL` | `https://github.com/AsahiLinux/linux.git` | Kernel source |
| `BRANCH` | *(asks, default `fairydust`)* | Branch to build; set it to skip the menu |
| `CLONE_DIR` | `$HOME/linux-fairydust` | Where to clone |
| `LOCALVERSION` | `-hdmifix` | Kernel name suffix / GRUB entry |
| `JOBS` | `$(nproc)` | Parallel build jobs |
| `ASSUME_YES` | `0` | Answer prompts automatically |
| `NO_REBOOT` | `0` | Never reboot, even unattended |
| `SKIP_PATCHES` | `0` | Build the branch unpatched |
| `PATCHES` | *(asks)* | Comma-separated filename substrings, case-insensitive |
| `UPDATE_SOURCE` | `1` | Set to `0` to never refresh an existing checkout |

## Patches

Everything in `patches/*.patch` is applied in filename order after cloning and before configuring. Already-applied patches are detected and skipped, so re-runs are safe. A patch that no longer applies is a hard error rather than a silent skip.

| Patch | What it does |
|---|---|
| `0001-drm-apple-reconnect-DP2HDMI-output-on-resume.patch` | The HDMI-after-suspend fix described above |
| `0002-sched-add-BORE-Burst-Oriented-Response-Enhancer.patch` | [BORE](https://github.com/firelzrd/bore-scheduler) scheduler. Optional and opinionated — delete it if you don't want it. Runtime-tunable via `/proc/sys/kernel/sched_bore`. |
| `0003-fairydust-usb-c-displayport-alt-mode.patch` | USB-C DisplayPort alt mode, for distros that build the release branch rather than `fairydust`. See below. |

Patches are self-describing. Each carries `X-Summary` and `X-Who-Needs-It`
headers ahead of the diff, which `patch` and `git apply` ignore, so the prompt
says what the patch does and who needs it rather than showing a raw kernel
commit subject. An unannotated patch dropped into `patches/` still works — it
falls back to the `Subject:` line, then the filename.

Patches that do not apply to the branch you chose are **not offered at all**.
They are reported as skipped, because "targets a different kernel version" is a
normal outcome, not a problem. The exception is a patch you named explicitly via
`PATCHES=`, which fails loudly instead of being quietly dropped.

Each remaining patch is offered as its own prompt, defaulting to yes, so you can take the HDMI fix and decline BORE:

```
[INFO]  Patches available in ./patches

    Everyone with a physical HDMI port (MacBook Pro 14/16, Mac mini).
    This is the point of this repo.
Apply: Fixes the built-in HDMI port staying dark after suspend [Y/n]:

    Optional and opinionated. Needs a 7.0 kernel and CONFIG_SCHED_BORE.
Apply: BORE scheduler - keeps the desktop responsive under heavy load [Y/n]: n
[INFO]  Skipped: 0002-sched-add-BORE-Burst-Oriented-Response-Enhancer.patch

[INFO]  Already in fairydust, nothing to do: USB-C DisplayPort output
```

Prompt text comes from each patch's `Subject:` line, so patches are self-describing. Non-interactive equivalents:

```bash
PATCHES=0001 ./asahi-fairydust-build.sh          # only the HDMI fix
PATCHES=hdmi,bore ./asahi-fairydust-build.sh     # by name, case-insensitive
ASSUME_YES=1 ./asahi-fairydust-build.sh          # all of them, no prompts
SKIP_PATCHES=1 ./asahi-fairydust-build.sh        # none
```

Drop your own `.patch` files in there and they will be picked up.

A [scheduled CI job](.github/workflows/patches-still-apply.yml) test-applies these against upstream `fairydust` every week, so a patch going stale surfaces there rather than two hours into someone's build.

## Which branch, and staying up to date

The script builds straight from **AsahiLinux/linux** and applies `patches/` on top at build time. There is no fork in the way, so every build picks up whatever upstream has published.

On startup it asks which branch you want:

| | Branch | Version | What it is |
|---|---|---|---|
| 1 | `fairydust` *(default)* | 7.0.13 | The main Asahi base plus experimental USB-C DisplayPort alt mode, so external displays over USB-C work. |
| 2 | `asahi` | 7.0.13 | The main Asahi branch, and what Fedora Asahi Remix builds its kernel from. Same base, without the USB-C alt mode work. |
| 3 | `asahi-wip` | 7.1.3 | Asahi's development branch. Newer and closer to upstream, less tested, no USB-C alt mode. |

**The HDMI suspend fix applies to all three** — `dcp.c` is identical on each, and the bug is present on all of them, including the stable `asahi` branch that most people are running.

Pick `fairydust` if you drive a monitor over USB-C as well as HDMI. Pick `asahi` if you only use the built-in HDMI port and would rather stay on the branch Fedora Asahi Remix ships. Pick `asahi-wip` if you want the newer base and accept it is less tested.

The BORE patch targets 7.0, so it applies to `asahi` and `fairydust` but not to `asahi-wip`. Decline it at the prompt if you pick option 3.

Skip the menu with `BRANCH=fairydust`, `BRANCH=asahi` or `BRANCH=asahi-wip`.

### Updating later

Re-run the script. It fetches the branch, shows you what is new, and asks before fast-forwarding:

```
[INFO]  Checking for upstream changes on fairydust ...
[INFO]  12 new commit(s) upstream:
        a1b2c3d drm/apple: ...
Update the source tree to origin/fairydust? [y/N]:
```

Say yes and it resets the tree, reapplies `patches/`, and rebuilds. Say no and it rebuilds what you already have. `UPDATE_SOURCE=0` skips the check entirely.

Note that the custom kernel is installed with `make install`, not as an RPM, so `dnf` does not manage it and will never update it on its own — re-running this script is the update mechanism. Your stock Fedora kernel keeps updating through `dnf` as normal and stays bootable in GRUB.

## Asahi ALARM (Arch Linux ARM)

The script detects the distribution and takes a different path on ALARM. Run it
the same way:

```bash
./asahi-fairydust-build.sh
```

On ALARM it skips branch selection, config seeding, m1n1 and GRUB entirely,
because none of that is its job there. ALARM's `linux-asahi` PKGBUILD already
loops over source entries ending in `.patch` and applies them with `patch -Np1`:

```bash
[[ $src = *.patch ]] || continue
patch -Np1 < "../$src"
```

So the script clones `asahi-alarm/PKGBUILDs`, asks which patches you want, drops
them into `linux-asahi/`, registers them in `source=()`, runs `updpkgsums`, and
offers to `makepkg -si`. The PKGBUILD pins its own upstream tag and Arch's
packaging handles the install, which is more reliable than reimplementing it.

`ALARM_PKGBUILDS_DIR` sets the checkout location (default `~/PKGBUILDs`).
`PATCHES`, `SKIP_PATCHES` and `ASSUME_YES` behave as they do on Fedora.

**What is verified, and what is not.** The patch applies with `patch -Np1`
against `AsahiLinux/linux` tag `asahi-7.0.13-1`, which is what ALARM's
`linux-asahi` currently builds, and the unfixed `dcp_platform_resume()` is
present at that tag. The `source=()` rewrite was tested against the real
PKGBUILD and leaves it parsing correctly. **`makepkg`, mkinitcpio and ALARM's
boot wiring are untested** — this was developed on Fedora. The script says so
when it runs. Your existing kernel package stays installed unless `makepkg -si`
succeeds. Reports welcome.

### Getting fairydust (USB-C DisplayPort) on ALARM

ALARM's `linux-asahi` builds the release branch, not `fairydust`, so the HDMI
fix alone does not give you USB-C DisplayPort output. `patches/0003` closes
that gap without changing which branch the package builds.

`fairydust` is exactly **13 commits ahead of `asahi-7.0.13-1` and 0 behind**,
so that delta is self-contained: DTS alt-mode hacks for every supported
machine, plus two tipd changes. Patch 0003 is that range, applied the same way
as everything else. Accept it at the prompt.

It is also useful on Fedora if you pick the `asahi` branch instead of
`fairydust`. On a `fairydust` tree it is detected as already applied and
skipped, so it is safe to leave enabled either way.

Caveats, inherited from upstream rather than introduced here:

- Upstream marks several of these commits `HACK` and treats `fairydust` as
  experimental.
- `ps_atc1_common` is forced always-on, which has battery implications on a
  laptop.
- Only one USB-C port drives a display.

**It tracks upstream rather than freezing.** A static patch would go stale two
ways: upstream adding commits to `fairydust`, and ALARM bumping its kernel tag.
So on ALARM the script reads the tag the PKGBUILD actually pins (via
`makepkg --printsrcinfo`, which expands the PKGBUILD's own variables) and
recomputes the range against it:

```
https://github.com/AsahiLinux/linux/compare/<that tag>...fairydust.diff
```

The file in `patches/` is a fallback used when the tag cannot be determined or
GitHub is unreachable, and the script says which one it used. `FAIRYDUST_REFRESH=0`
forces the shipped snapshot.

The Fedora path never needed this: choosing the `fairydust` branch clones it
directly, so it is current by construction and patch 0003 self-skips.

Verified: applies with `patch -Np1` to `asahi-7.0.13-1`, coexists with patch
0001, reverse-detects on a `fairydust` tree, and the regenerated patch is
byte-identical to the shipped one right now and applies cleanly. Not
boot-tested — see above.

BORE needs more than a patch on ALARM: its kernel `config` has no
`CONFIG_SCHED_BORE`, so the patch would apply but the feature would compile out.
The script warns if you select it.

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

## Caveats

- Custom kernel. **Module signing is disabled.**
- `dnf` will keep updating your stock kernel; this one stays until you rebuild.
- When upstream moves, re-run the script and accept the update prompt.
- The `fairydust` branch is experimental and not officially supported by the Asahi team.

## Credits

This repository is a fork and stands almost entirely on other people's work.

- **[bharambetejas/asahi-fairydust-display](https://github.com/bharambetejas/asahi-fairydust-display)** by Tejas Bharambe — the original build script, and the reason any of this was approachable. It solves the genuinely hard parts: seeding the config from your running kernel, getting Rust and the GPU driver enabled so you do not end up on llvmpipe, and wiring up m1n1 and GRUB correctly. This fork adds a patch step and some build fixes on top; the generic improvements have been sent back upstream as pull requests.
- **[Asahi Linux team](https://asahilinux.org/)** (marcan, Sven Peter, Janne Grunau, and everyone else) for the kernel, the `fairydust` branch, and years of reverse engineering that made Linux on Apple Silicon exist at all. The fix here is two lines in a driver they wrote from scratch against undocumented hardware. Finding a gap in it is a very different thing from building it.
- **[r/AsahiLinux](https://www.reddit.com/r/AsahiLinux/)** and the wider Asahi community, whose bug reports and troubleshooting threads made this identifiable as a real reproducible issue rather than one broken machine.
- **[Claude](https://claude.com/claude-code)** (Anthropic) for the debugging work that located the root cause. After the usual suspects were exhausted — including trying `fairydust`, which turned out to be the wrong branch entirely — reading through the DCP driver's suspend and resume paths with Claude Code is what surfaced the missed edge-triggered HPD and the already-existing helper that resume should have been calling.
- Build process follows the [Asahi progress report](https://asahilinux.org/2026/02/progress-report-6-19/).

Prior reports of the HDMI issue:
[Fedora discussion](https://discussion.fedoraproject.org/t/hdmi-output-after-suspend-to-ram-on-macbook-pro/101597),
[AsahiLinux/docs#94](https://github.com/AsahiLinux/docs/issues/94).

## Tested on

MacBook Pro 14-inch M1 Pro (`apple,j314s`), Fedora Asahi Remix 44, kernel 7.0.13.

Reports from other models welcome — particularly M1 Max, M2 Pro/Max and Mac mini, which have the same built-in HDMI path and should behave identically.

## License

MIT
