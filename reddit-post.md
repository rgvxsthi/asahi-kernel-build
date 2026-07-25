# r/AsahiLinux post draft

**Title:** Built-in HDMI not waking after suspend — found the actual cause, it's a two-line kernel fix

---

MacBook Pro 14" M1 Pro on Fedora Asahi Remix. Every time I suspended with my HDMI monitor plugged in, it stayed dark on wake. Internal panel fine, external dead. The only thing that brought it back was physically unplugging and replugging the cable — every single time.

First thing I tried was the `fairydust` kernel branch, since that's the usual answer for external display problems here. **It didn't fix it.** Turns out `fairydust`'s `dcp.c` is byte-identical to `asahi-wip` — I diffed them. fairydust adds USB-C DisplayPort alt mode, which is a completely separate output path from the built-in HDMI port. If your HDMI is the physical port on the side of the laptop, fairydust does nothing for this.

So I sat down with Claude Code and went through the DCP driver properly. It's small and specific.

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

That interrupt is **edge triggered** — the driver says so in its own comment. If the monitor was never unplugged, there's no edge across the suspend, the handler never fires, and `dcp_dptx_connect()` is never called again. The port just sits there disconnected. Replugging works because you're manually generating the edge the driver is sitting there waiting for.

The driver already has the correct helper. `dcp_enable_dp2hdmi_hpd()` reads the HPD GPIO, reconnects if a display is present, *then* enables the interrupt — and it's already used from `dcp_wait_ready()`. Resume just wasn't calling it:

```diff
  	if (dcp->hdmi_hpd_irq)
- 		enable_irq(dcp->hdmi_hpd_irq);
+ 		dcp_enable_dp2hdmi_hpd(dcp);
```

Before, resume was silent on the HDMI DCP. After:

```
[108.345] apple-dcp 289c00000.dcp: dcp_dptx_disconnect(port=0)
[108.634] apple-dcp 289c00000.dcp: dcp_enable_dp2hdmi_hpd: DP2HDMI HPD connected:1
[108.634] apple-dcp 289c00000.dcp: dcp_dptx_connect(port=0)
[109.409] PM: suspend exit
```

Monitor comes straight back. No replug.

## Running it

I forked Tejas Bharambe's excellent [asahi-fairydust-display](https://github.com/bharambetejas/asahi-fairydust-display) build script — it already handles deps, seeding the config from your running kernel, Rust/GPU so you don't land on llvmpipe, and m1n1/GRUB. My fork adds a `patches/` step carrying the fix:

```bash
git clone https://github.com/rgvxsthi/asahi-linux-hdmi-sleep-fixer.git
cd asahi-linux-hdmi-sleep-fixer
./asahi-fairydust-build.sh
```

Takes 1.5–3 hours. If you have 16 GB RAM, use `JOBS=6 ./asahi-fairydust-build.sh` — a full `-j$(nproc)` will thrash. Reboot, pick the `-rgvx` entry in GRUB.

**Your stock kernel is untouched and stays in GRUB**, so rollback is just picking it at boot. Fair warning: it's a custom kernel with module signing disabled, and you own the rebuild every time upstream moves.

Kernel branch is at [rgvxsthi/linux](https://github.com/rgvxsthi/linux), branch `rgvx/fairydust` — upstream `fairydust` (7.0.13) plus the HDMI fix, plus BORE since I was rebuilding anyway.

I've also sent the fix and the build fixes back upstream as PRs, so hopefully this ends up somewhere more central than my fork.

## One thing that saves you time

Don't bother with a userspace workaround. I tried `echo detect > /sys/class/drm/cardN-HDMI-A-1/status` (no effect — DRM's detect just mirrors the DCP's state), poking the Type-C alt-mode sysfs (wrong subsystem entirely for the built-in port), and a resume hook that cycles the output with `kscreen-doctor`. That last one can't work — kscreen can only cycle an output that exists, and here the connector is disconnected at the kernel level. Mine actively wedged my display once. It's a kernel bug and it needs a kernel fix.

Credit where it's due: the Asahi team wrote this entire driver by reverse engineering undocumented hardware. Finding a two-line gap in it is a very different thing from building it.

---

## Notes before posting

- Verify both PR numbers are still accurate: #7 (build fixes) and #8 (patches + HDMI fix).
- Consider linking the two bug reports if people ask for prior art:
  https://discussion.fedoraproject.org/t/hdmi-output-after-suspend-to-ram-on-macbook-pro/101597
  and https://github.com/AsahiLinux/docs/issues/94
- Expect "why not submit to the Asahi tree directly" — have an answer ready.
