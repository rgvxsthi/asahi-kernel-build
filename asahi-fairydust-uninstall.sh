#!/bin/bash
# =============================================================================
# asahi-fairydust-uninstall.sh
#
# Cleanly removes the fairydust kernel and reverts to the stock Fedora Asahi
# kernel. Run this from the STOCK kernel (not the fairydust kernel).
#
# USAGE:
#   chmod +x asahi-fairydust-uninstall.sh
#   ./asahi-fairydust-uninstall.sh
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

confirm() {
    # Same contract as the build script's confirm(): ASSUME_YES makes an
    # unattended run possible, and a closed stdin is an error rather than a
    # silent "no", which would otherwise look like the uninstall ran and
    # decided against everything.
    if [[ "${ASSUME_YES:-0}" == "1" ]]; then
        info "$1 [auto-yes]"
        return 0
    fi
    if ! read -rp "$(echo -e "${YELLOW}$1 [y/N]:${NC} ")" response; then
        error "No input available (stdin closed). Re-run attached to a terminal,
or set ASSUME_YES=1 to answer prompts automatically."
    fi
    [[ "$response" =~ ^[Yy]$ ]]
}

echo ""
echo "============================================================"
echo "  Asahi Linux Fairydust Kernel Uninstaller"
echo "============================================================"
echo ""

# Which kernels count as ours. LOCALVERSION is what the build script tags the
# kernel with, and it has changed over time, so match the current default plus
# the suffixes earlier builds used. Anything installed by hand with a custom
# LOCALVERSION can be matched by exporting the same value here.
#
# Matching only "fairydust" was a real bug: once the default became -hdmifix,
# this script reported that there was nothing to uninstall while a custom
# kernel was plainly installed, and the safety check below never fired.
KERNEL_SUFFIXES="${LOCALVERSION:--hdmifix} -fairydust -rgvx"
# Sanitised: this pattern drives which module directories get removed, and the
# comment above invites users to export their own LOCALVERSION, so it must not
# be able to carry regex metacharacters.
KVER_PATTERN="$(printf '%s\n' $KERNEL_SUFFIXES \
    | sed 's/^-//; s/[^A-Za-z0-9_+]//g' \
    | grep -v '^$' | sort -u | paste -sd'|')"
[[ -z "$KVER_PATTERN" ]] && error "No usable kernel suffix to match on."

# Safety check — don't uninstall the kernel we are currently running
if uname -r | grep -qE "$KVER_PATTERN"; then
    error "You are currently running a custom kernel ($(uname -r)).
Reboot into your stock Asahi kernel first, then run this script."
fi

info "Current kernel: $(uname -r)"
info "Looking for kernels matching: $KVER_PATTERN"
echo ""

# Find custom kernel version(s)
FAIRYDUST_KVERS=""
for _d in /usr/lib/modules/*/; do
    [[ -d "$_d" ]] || continue
    _k="$(basename "$_d")"
    [[ "$_k" =~ $KVER_PATTERN ]] && FAIRYDUST_KVERS+="$_k"$'\n'
done
FAIRYDUST_KVERS="${FAIRYDUST_KVERS%$'\n'}"
if [[ -z "$FAIRYDUST_KVERS" ]]; then
    info "No custom kernel found. Nothing to uninstall."
    exit 0
fi

echo "Found custom kernel(s):"
for kver in $FAIRYDUST_KVERS; do
    echo "  - $kver"
done
echo ""

if ! confirm "Remove the fairydust kernel and all associated files?"; then
    info "Aborted."
    exit 0
fi

for KVER in $FAIRYDUST_KVERS; do
    info "Removing kernel: $KVER"

    # Remove kernel files from /boot
    sudo rm -f "/boot/vmlinuz-$KVER"
    sudo rm -f "/boot/initramfs-$KVER.img"
    sudo rm -f "/boot/System.map-$KVER"
    sudo rm -f "/boot/config-$KVER"

    # Remove modules
    sudo rm -rf "/usr/lib/modules/$KVER"

    # Remove DTBs
    sudo rm -rf "/boot/dtbs/$KVER"

    ok "Removed $KVER"
done

# Remove typec module autoload
if [[ -f /etc/modules-load.d/fairydust-typec.conf ]]; then
    sudo rm -f /etc/modules-load.d/fairydust-typec.conf
    ok "Removed typec module autoload config"
fi

# The three blocks below clean up files this script's own builder never
# creates. They come from the upstream fork's older script, which did install a
# display hotplug rule and an autostart entry. Anyone who ran that first and
# this uninstaller second would otherwise be left with them, so the blocks stay.
# They are no-ops on a machine that only ever ran the current builder.

# Remove udev hotplug rule
if [[ -f /etc/udev/rules.d/95-fairydust-hotplug.rules ]]; then
    sudo rm -f /etc/udev/rules.d/95-fairydust-hotplug.rules
    sudo udevadm control --reload-rules
    ok "Removed udev hotplug rule"
fi

# Remove display script and autostart
if [[ -f "$HOME/display-setup.sh" ]]; then
    rm -f "$HOME/display-setup.sh"
    ok "Removed display setup script"
fi

if [[ -f "$HOME/.config/autostart/fairydust-display.desktop" ]]; then
    rm -f "$HOME/.config/autostart/fairydust-display.desktop"
    ok "Removed autostart entry"
fi

# Restore m1n1 to stock kernel DTBs
info "Restoring m1n1 bootloader..."
STOCK_KVER=$(uname -r)
if [[ -L /boot/dtb ]]; then
    sudo ln -sfn "dtb-$STOCK_KVER" /boot/dtb
fi

# Restore /etc/sysconfig/update-m1n1 DTBS path
if [[ -f /etc/sysconfig/update-m1n1 ]]; then
    # Anchored, and only non-commented lines: the previous pattern matched any
    # line containing DTBS=, including commented-out ones, and activated them.
    sudo sed -i 's|^[[:space:]]*DTBS=.*|DTBS="/boot/dtb"|' /etc/sysconfig/update-m1n1
fi

sudo ln -sfn "/usr/lib/modules/$STOCK_KVER" /usr/src/linux
sudo update-m1n1
ok "m1n1 restored to stock kernel"

# Regenerate GRUB
info "Regenerating GRUB..."
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
ok "GRUB regenerated"

# Optionally remove source tree
echo ""
# Honour the same override the build script uses, so a non-default tree is
# still offered for removal.
CLONE_DIR="${CLONE_DIR:-$HOME/linux-fairydust}"
if [[ -d "$CLONE_DIR" ]]; then
    SOURCE_SIZE=$(du -sh "$CLONE_DIR" | awk '{print $1}')
    if confirm "Remove kernel source tree at $CLONE_DIR ($SOURCE_SIZE)?"; then
        rm -rf "$CLONE_DIR"
        ok "Source tree removed"
    else
        info "Source tree kept at $CLONE_DIR"
    fi
fi

# Also check for ~/linux
if [[ -d "$HOME/linux" ]] && [[ -f "$HOME/linux/.config" ]]; then
    if grep -qE "$KVER_PATTERN" "$HOME/linux/.config" 2>/dev/null; then
        SOURCE_SIZE=$(du -sh "$HOME/linux" | awk '{print $1}')
        if confirm "Found fairydust source at ~/linux ($SOURCE_SIZE). Remove?"; then
            rm -rf "$HOME/linux"
            ok "Source tree removed"
        fi
    fi
fi

echo ""
echo "============================================================"
echo -e "  ${GREEN}UNINSTALL COMPLETE${NC}"
echo "============================================================"
echo ""
echo "  Your system is back to the stock Fedora Asahi kernel."
echo "  Current kernel: $(uname -r)"
echo ""
echo "============================================================"
