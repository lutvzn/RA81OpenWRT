#!/bin/bash
# Simulates the RA81 dual-boot protocol end to end: the real
# /lib/functions/xiaomi-dualboot.sh from the OpenWrt tree runs against a
# file-backed U-Boot environment, and U-Boot's slot selection is modelled
# exactly as disassembled from the RA81 APPSBL (see AGENTS.md).
#
#   tools/test-dualboot.sh [path/to/xiaomi-dualboot.sh]
set -u

TOP=$(cd "$(dirname "$0")/.." && pwd)
# Default: the build tree named in patches/BASE, as scripts/build.sh uses it
SRC=${SRC:-$(sed -n 's/^SRC=//p' "$TOP/patches/BASE")}
case "$SRC" in /*) ;; *) SRC=$TOP/${SRC:-build/openwrt} ;; esac
LIB=${1:-$SRC/target/linux/qualcommax/ipq50xx/base-files/lib/functions/xiaomi-dualboot.sh}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

ENV=$T/env
CMDLINE=$T/cmdline
mkdir -p "$T/bin" "$T/tmp"

# --- stubs ---------------------------------------------------------------------
cat > "$T/bin/fw_printenv" <<EOF
#!/bin/bash
# fw_printenv [-c cfg] [-n] name
n=; while [ \$# -gt 0 ]; do case "\$1" in -c) shift;; -n) n=1;; *) name=\$1;; esac; shift; done
v=\$(grep -m1 "^\$name=" "$ENV") || { echo "## Error: \"\$name\" not defined" >&2; exit 1; }
[ -n "\$n" ] && echo "\${v#*=}" || echo "\$v"
EOF
cat > "$T/bin/fw_setenv" <<EOF
#!/bin/bash
# fw_setenv [-c cfg] -s script   |   fw_setenv name [value]
while [ \$# -gt 0 ]; do case "\$1" in -c) shift;; -s) script=\$2; shift;; *) break;; esac; shift; done
apply() { grep -v "^\$1=" "$ENV" > "$ENV.new"; [ -n "\$2" ] && echo "\$1=\$2" >> "$ENV.new"; mv "$ENV.new" "$ENV"; }
if [ -n "\${script:-}" ]; then
	while read -r name value; do [ -n "\$name" ] && apply "\$name" "\$value"; done < "\$script"
else
	apply "\$1" "\${2:-}"
fi
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

# Library under test, with /proc/cmdline and /tmp redirected into the sandbox
sed -e "s#/tmp/#$T/tmp/#g" -e "s#/proc/cmdline#$CMDLINE#g" -e 's#^\. /lib/functions.sh#:#' \
	-e 's#mkdir -p /var/lock#:#' "$LIB" > "$T/lib.sh"
cat >> "$T/lib.sh" <<'EOF'
find_mtd_index() { [ "$1" = "0:appsblenv" ] && echo 10; }
EOF

getv() { sed -n "s/^$1=//p" "$ENV"; }
setv() { grep -v "^$1=" "$ENV" > "$ENV.new"; [ -n "${2:-}" ] && echo "$1=$2" >> "$ENV.new"; mv "$ENV.new" "$ENV"; }
num() { local v; v=$(getv "$1"); echo "${v:-0}"; }

# --- U-Boot model (bootmiwifi, RA81 APPSBL 0x4a92232c + caller) -----------------
uboot_select() {
	local s1 s2 ota last slot bs
	s1=$(num flag_try_sys1_failed); s2=$(num flag_try_sys2_failed)
	ota=$(num flag_ota_reboot); last=$(num flag_last_success)
	if [ "$s1" -gt 1 ] || [ "$s2" -gt 1 ] || [ "$ota" -gt 1 ] || [ "$last" -gt 1 ]; then
		slot=0
	elif [ "$ota" = 1 ]; then
		slot=$((1 - last))
		bs=$(getv flag_boot_success)
		if [ -n "$bs" ] && [ "$bs" = 0 ]; then
			echo "    U-Boot: ota reboot failed, swap to old firmware!"
			slot=$last; setv flag_ota_reboot; setv flag_upgrade_push
		fi
	else
		local failed=$s1; [ "$last" != 0 ] && failed=$s2
		if [ "$failed" != 0 ]; then slot=$((1 - last)); else slot=$last; fi
	fi
	setv flag_boot_rootfs "$slot"
	echo "$slot"
}

# Boot one cycle. $1 = behaviour of the image in the selected slot:
#   ok | crash-after-preinit | hang-before-preinit | bad-image
# Slot images are tracked in $T/slot0, $T/slot1 (contents: "ours", "old", "bad").
boot() {
	local slot img behaviour
	slot=$(uboot_select | tail -n1)
	img=$(cat "$T/slot$slot")
	echo "  boot -> slot $slot ($img)"
	if [ "$img" = bad ]; then
		echo "    U-Boot: bad image, flag_try_sys$((slot + 1))_failed=1"
		setv "flag_try_sys$((slot + 1))_failed" 1; setv flag_ota_reboot 0
		return
	fi
	[ "$slot" = 0 ] && echo "ubi.mtd=rootfs root=mtd:ubi_rootfs root=/dev/ubiblock0_1" > "$CMDLINE" \
	                || echo "ubi.mtd=rootfs_1 root=mtd:ubi_rootfs root=/dev/ubiblock0_1" > "$CMDLINE"
	behaviour=${1:-ok}
	rm -f "$T/tmp/"*
	case "$img" in
	ours)
		[ "$behaviour" = hang-before-preinit ] && { echo "    (kernel hangs before preinit)"; return; }
		(. "$T/lib.sh"; xiaomi_dualboot_arm)
		[ "$behaviour" = crash-after-preinit ] && { echo "    (crash after preinit)"; return; }
		(. "$T/lib.sh"; xiaomi_dualboot_confirm)
		;;
	old)
		# hzyitc QSDK firmware's /etc/init.d/uboot_env
		if [ "$(getv flag_ota_reboot)" = 1 ]; then
			setv flag_last_success "$slot"; setv flag_ota_reboot 0; setv flag_boot_success 1
		fi
		;;
	esac
}

# The installer's / sysupgrade's flag sequence after writing the inactive slot
arm_trial() {
	local running=$1
	setv flag_try_sys1_failed 0; setv flag_try_sys2_failed 0
	setv flag_last_success "$running"; setv flag_boot_success; setv flag_ota_reboot 1
}

# sysupgrade from the running image, through the real xiaomi_dualboot_setenv
sysupgrade_flags() {
	(. "$T/lib.sh"; slot=$(xiaomi_dualboot_slot); xiaomi_dualboot_setenv \
		"flag_try_sys1_failed 0" "flag_try_sys2_failed 0" "flag_last_success $slot" \
		"flag_boot_success" "flag_ota_reboot 1")
}

reset_state() {
	printf 'flag_boot_rootfs=0\nflag_last_success=0\nflag_ota_reboot=0\nflag_boot_success=1\nflag_try_sys1_failed=0\nflag_try_sys2_failed=0\nmodel=RA81\n' > "$ENV"
	echo old > "$T/slot0"; echo empty > "$T/slot1"
}

fail=0
expect() { # expect <description> <expected slot of the next boot>
	local got; got=$(uboot_select | tail -n1)
	# selection has side effects only for rollback; undo flag_boot_rootfs change is harmless
	if [ "$got" = "$2" ]; then echo "  OK   $1 (next boot: slot $got)"; else echo "  FAIL $1 (next boot: slot $got, expected $2)"; fail=1; fi
}
show() { echo "    env: $(grep flag_ "$ENV" | sort | tr '\n' ' ')"; }

echo "== 1. First install into slot 1 from the old firmware, new image boots fine"
reset_state; echo ours > "$T/slot1"; arm_trial 0
boot ok; show; boot ok; boot ok; show
expect "new firmware sticks" 1

echo "== 2. New image crashes after preinit -> rollback to old firmware"
reset_state; echo ours > "$T/slot1"; arm_trial 0
boot crash-after-preinit; show; boot ok; show; boot ok
expect "old firmware is default again" 0

echo "== 3. New image is unbootable -> U-Boot falls back by itself"
reset_state; echo bad > "$T/slot1"; arm_trial 0
boot; show; boot ok; show
expect "old firmware is default again" 0

echo "== 4. Running our firmware in slot 1, sysupgrade writes slot 0, boots fine"
reset_state; echo ours > "$T/slot1"; arm_trial 0; boot ok
echo ours > "$T/slot0"; sysupgrade_flags; show
boot ok; show
expect "upgraded slot 0 sticks" 0

echo "== 5. sysupgrade from slot 1, new slot 0 crashes after preinit -> back to slot 1"
reset_state; echo ours > "$T/slot1"; arm_trial 0; boot ok
echo ours > "$T/slot0"; sysupgrade_flags
boot crash-after-preinit; boot ok; show
expect "previous slot 1 is default again" 1

echo "== 6. Known limitation: kernel hangs before preinit -> U-Boot keeps retrying the new slot"
reset_state; echo ours > "$T/slot1"; arm_trial 0
boot hang-before-preinit; show
expect "U-Boot retries new slot (needs TFTP recovery if it never boots)" 1

echo "== 7. Confirm is idempotent (no env writes on a normal boot)"
reset_state; echo ours > "$T/slot1"; arm_trial 0; boot ok
boot ok
(. "$T/lib.sh"; xiaomi_dualboot_confirm); cp "$ENV" "$T/e1"; (. "$T/lib.sh"; xiaomi_dualboot_confirm)
if cmp -s "$ENV" "$T/e1"; then echo "  OK   second confirm changes nothing"; else echo "  FAIL confirm rewrote env"; fail=1; fi

echo
[ $fail = 0 ] && echo "ALL SCENARIOS PASSED" || echo "SOME SCENARIOS FAILED"
exit $fail
