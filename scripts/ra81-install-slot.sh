#!/bin/sh
# Install an OpenWrt factory.ubi image into the *inactive* dual-boot slot of
# a Redmi AX3000 (RA81) and arm a one-time trial boot of it.
#
# Runs on the router (busybox ash), from any firmware that boots through the
# stock Xiaomi U-Boot ("bootmiwifi") and has ubiformat/fw_setenv available,
# e.g. the hzyitc/ImmortalWrt QSDK builds or this project's OpenWrt build.
#
# What it touches:   the inactive slot partition (rootfs or rootfs_1) and the
#                    flag_* variables of the U-Boot environment.
# What it never touches: the running slot, bootloaders, ART/calibration,
#                    bdata, or any other partition.
#
# Recovery: if the new system does not finish booting, power-cycle the router;
# U-Boot then rolls back to the current slot (see AGENTS.md, "Dual boot").
#
# Usage: ra81-install-slot.sh [--yes] [--reboot] IMAGE.ubi [SHA256]

set -e

YES=
REBOOT=
while [ $# -gt 0 ]; do
	case "$1" in
	--yes) YES=1 ;;
	--reboot) REBOOT=1 ;;
	-*) echo "unknown option: $1" >&2; exit 2 ;;
	*) break ;;
	esac
	shift
done

IMAGE="$1"
SHA256="$2"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$IMAGE" ] || die "usage: $0 [--yes] [--reboot] IMAGE.ubi [SHA256]"
[ -f "$IMAGE" ] || die "$IMAGE not found"

for tool in ubiformat ubiattach ubidetach ubinfo fw_printenv fw_setenv sha256sum; do
	command -v $tool >/dev/null || die "$tool is missing on this system"
done

# --- Device checks ---------------------------------------------------------
compat=$(tr '\0' ' ' < /proc/device-tree/compatible)
case "$compat" in
*redmi,ax3000*|*xiaomi,redmi-ax3000*) ;;
*) die "not a Redmi AX3000 (compatible: $compat)" ;;
esac

model=$(fw_printenv -n model 2>/dev/null || true)
[ "$model" = RA81 ] || die "U-Boot env model is '$model', expected RA81 (check /etc/fw_env.config)"

mtd_index() {
	sed -n "s/^mtd\([0-9]*\): [0-9a-f]* [0-9a-f]* \"$1\"$/\1/p" /proc/mtd
}
mtd_size() {
	sed -n "s/^mtd[0-9]*: \([0-9a-f]*\) [0-9a-f]* \"$1\"$/\1/p" /proc/mtd
}

# fw_setenv must write to the U-Boot env partition (0:APPSBLENV / 0:appsblenv)
env_mtd=$(mtd_index '0:APPSBLENV'); [ -n "$env_mtd" ] || env_mtd=$(mtd_index '0:appsblenv')
[ -n "$env_mtd" ] || die "U-Boot env partition not found"
grep -q "^/dev/mtd$env_mtd[[:space:]]" /etc/fw_env.config || \
	die "/etc/fw_env.config does not point to /dev/mtd$env_mtd"

# --- Slot selection ------------------------------------------------------------
running=$(sed -n 's/.*ubi\.mtd=\([^ ]*\).*/\1/p' /proc/cmdline)
case "$running" in
rootfs)   slot=0; target=rootfs_1 ;;
rootfs_1) slot=1; target=rootfs ;;
*) die "cannot determine the running slot (ubi.mtd=$running)" ;;
esac

tmtd=$(mtd_index "$target")
[ -n "$tmtd" ] || die "partition $target not found"
tsize=$((0x$(mtd_size "$target")))

for d in /sys/class/ubi/ubi[0-9]*; do
	[ -e "$d/mtd_num" ] || continue
	[ "$(cat "$d/mtd_num")" = "$tmtd" ] && die "$target (mtd$tmtd) is attached as $(basename "$d"); refusing"
done
grep -q "^/dev/mtdblock$tmtd " /proc/mounts && die "$target is mounted; refusing"

# --- Image checks ----------------------------------------------------------------
[ "$(head -c 4 "$IMAGE")" = "UBI#" ] || die "$IMAGE is not a UBI image (use *-squashfs-factory.ubi)"
isize=$(wc -c < "$IMAGE")
[ "$isize" -le "$tsize" ] || die "image ($isize bytes) larger than $target ($tsize bytes)"
isum=$(sha256sum "$IMAGE" | cut -d' ' -f1)
if [ -n "$SHA256" ]; then
	[ "$isum" = "$SHA256" ] || die "sha256 mismatch: got $isum"
fi

echo "Running slot : $slot ($running)"
echo "Target slot  : $((1 - slot)) ($target = /dev/mtd$tmtd, $tsize bytes)"
echo "Image        : $IMAGE ($isize bytes, sha256 $isum)"
echo "U-Boot flags :"
for v in flag_boot_rootfs flag_last_success flag_ota_reboot flag_boot_success flag_try_sys1_failed flag_try_sys2_failed; do
	echo "  $v=$(fw_printenv -n $v 2>/dev/null || echo '<unset>')"
done

if [ -z "$YES" ]; then
	echo
	echo "Dry run only. Re-run with --yes to flash $target and arm a trial boot."
	exit 0
fi

# --- Flash -----------------------------------------------------------------------
echo "Flashing $target ..."
ubiformat "/dev/mtd$tmtd" -f "$IMAGE" -y

echo "Verifying UBI volumes on $target ..."
ubiattach -m "$tmtd" -d 7 >/dev/null
vols=$(ubinfo -d 7 -a | sed -n 's/^Name:[[:space:]]*//p' | tr '\n' ' ')
ubidetach -d 7 >/dev/null
echo "  volumes: $vols"
for v in kernel rootfs; do
	case " $vols " in
	*" $v "*) ;;
	*) die "volume '$v' missing after flashing; NOT switching slots" ;;
	esac
done

# --- Arm a one-time trial boot of the new slot ------------------------------------
script=/tmp/ra81-install.fw_setenv
cat > "$script" <<EOF
flag_try_sys1_failed 0
flag_try_sys2_failed 0
flag_last_success $slot
flag_boot_success
flag_ota_reboot 1
EOF
fw_setenv -s "$script"
rm -f "$script"

echo
echo "Done. On the next boot U-Boot will try slot $((1 - slot)) ($target)."
echo "If it does not come up, power-cycle: U-Boot rolls back to slot $slot."
echo "To cancel before rebooting: fw_setenv flag_ota_reboot 0"

[ -n "$REBOOT" ] && reboot
exit 0
