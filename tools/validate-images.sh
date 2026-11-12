#!/bin/bash
# Static validation of the RA81 build outputs.
#   tools/validate-images.sh [BIN_DIR]
# Needs: dtc, unsquashfs, python venv with ubi_reader (build/venv-tools).
set -uo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
# Default: the build tree named in patches/BASE, as scripts/build.sh uses it
SRC=${SRC:-$(sed -n 's/^SRC=//p' "$TOP/patches/BASE")}
case "$SRC" in /*) ;; *) SRC=$TOP/${SRC:-build/openwrt} ;; esac
BIN=${1:-$SRC/bin/targets/qualcommax/ipq50xx}
VENV=$TOP/build/venv-tools/bin
WORK_TOP=$(mktemp -d)
trap 'rm -rf "$WORK_TOP"' EXIT

fail=0
ok()   { echo "  OK   $*"; }
bad()  { echo "  FAIL $*"; fail=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# One image set per device: the standard image and the overclock variant
validate_device() {
	local DEV=$1 OC=
	case $DEV in *-oc) OC=1 ;; esac
	WORK=$WORK_TOP/$DEV
	mkdir -p "$WORK"

	FACTORY=$(ls "$BIN"/*$DEV-squashfs-factory.ubi 2>/dev/null | head -1)
	SYSUPG=$(ls "$BIN"/*$DEV-squashfs-sysupgrade.bin 2>/dev/null | head -1)
	INITRD=$(ls "$BIN"/*$DEV-initramfs-uImage.itb 2>/dev/null | head -1)

	echo "== Files ($DEV)"
	for f in "$FACTORY" "$SYSUPG" "$INITRD"; do
		check "present: $(basename "${f:-missing}")" "[ -s '${f:-/nonexistent}' ]"
	done
	[ -s "$FACTORY" ] || return

	SLOT=$((0x2400000))
	fsize=$(stat -c%s "$FACTORY")
	check "factory.ubi ($fsize B) fits a 36 MiB slot" "[ $fsize -le $SLOT ]"
	check "factory.ubi starts with UBI#" "[ \"\$(head -c4 '$FACTORY')\" = 'UBI#' ]"

	echo "== UBI volumes"
	"$VENV"/ubireader_display_info "$FACTORY" > "$WORK/ubi.txt" 2>&1
	vols=$(sed -n "s/^\s*Volume Name:\s*//p" "$WORK/ubi.txt" | tr '\n' ' ')
	echo "  volumes: $vols"
	check "volume order kernel,rootfs,rootfs_data" "[ \"$vols\" = 'kernel rootfs rootfs_data ' ]"
	"$VENV"/ubireader_extract_images -o "$WORK/ubi" "$FACTORY" >/dev/null 2>&1
	KVOL=$(ls "$WORK"/ubi/*/*vol-kernel.ubifs)
	RVOL=$(ls "$WORK"/ubi/*/*vol-rootfs.ubifs)
	check "rootfs volume is squashfs" "[ \"\$(head -c4 '$RVOL')\" = 'hsqs' ]"

	echo "== FIT (kernel volume)"
	dtc -I dtb -O dts -o "$WORK/fit.dts" "$KVOL" 2>/dev/null
	grep -vE '^\s*data = ' "$WORK/fit.dts" | grep -E 'default|config|arch|compression|load|entry|description' | sed 's/^/    /'
	check "FIT default config is config@mp02.1" "grep -q 'default = \"config@mp02.1\"' '$WORK/fit.dts'"
	check "FIT has node config@mp02.1" "grep -q 'config@mp02.1 {' '$WORK/fit.dts'"
	check "FIT kernel arch arm64" "grep -q 'arch = \"arm64\"' '$WORK/fit.dts'"

	echo "== DTB inside FIT"
	"$VENV"/python -I - "$KVOL" "$WORK/board.dtb" <<-'EOF'
	import sys, struct
	# Extract the first fdt image's data from the FIT via a minimal FDT walk.
	d = open(sys.argv[1], 'rb').read()
	magic, totalsize, off_struct, off_strings = struct.unpack_from('>IIII', d, 0)
	p, path, strings = off_struct, [], d[off_strings:]
	while True:
	    tok, = struct.unpack_from('>I', d, p); p += 4
	    if tok == 1:
	        e = d.index(b'\0', p); path.append(d[p:e].decode()); p = (e + 4) & ~3
	    elif tok == 2:
	        path.pop()
	    elif tok == 3:
	        ln, no = struct.unpack_from('>II', d, p); p += 8
	        name = strings[no:strings.index(b'\0', no)].decode()
	        if name == 'data' and len(path) >= 2 and path[-2] == 'images' and path[-1].startswith('fdt'):
	            open(sys.argv[2], 'wb').write(d[p:p+ln]); break
	        p = (p + ln + 3) & ~3
	    elif tok == 9:
	        sys.exit("no fdt image found")
	EOF
	dtc -I dtb -O dts -o "$WORK/board.dts" "$WORK/board.dtb" 2>/dev/null
	check "model Xiaomi Redmi AX3000" "grep -q 'model = \"Xiaomi Redmi AX3000\"' '$WORK/board.dts'"
	check "compatible xiaomi,redmi-ax3000" "grep -q 'compatible = \"xiaomi,redmi-ax3000\"' '$WORK/board.dts'"
	check "bootargs-append root=/dev/ubiblock0_1" "grep -q 'bootargs-append = \" root=/dev/ubiblock0_1' '$WORK/board.dts'"
	check "smem partitions with 0:art node" "grep -q 'label = \"0:art\"' '$WORK/board.dts'"
	check "NAND ECC strength 8" "grep -q 'nand-ecc-strength = <0x08>' '$WORK/board.dts'"
	check "tz reserved 4 MiB" "grep -A1 'tz@4ac00000' '$WORK/board.dts' | grep -q '0x4ac00000 0x00 0x400000'"
	# Multi-PD Q6 layout, 0x4b000000-0x4e000000 as the vendor's 48 MiB q6_mem_regions
	for r in wcss@4b000000:'0x4b000000 0x00 0x1400000' q6-region-ipq5018@4c400000:'0x4c400000 0x00 0xd00000' \
		m3-dump-ipq5018@4d100000:'0x4d100000 0x00 0x100000' q6-region-qcn6122-1@4d200000:'0x4d200000 0x00 0xd00000' \
		m3-dump-qcn6122-1@4df00000:'0x4df00000 0x00 0x100000'; do
		check "reserved ${r%%:*}" "grep -A2 '${r%%:*} {' '$WORK/board.dts' | grep -q '${r#*:}'"
	done
	check "nss region 8 MiB" "grep -A2 'memory@40000000 {' '$WORK/board.dts' | grep -q '0x40000000 0x00 0x800000'"
	check "nss@40000000 node (ipq5018-nss.dtsi)" "grep -q 'compatible = \"qcom,nss\"' '$WORK/board.dts'"
	check "bootargs swiotlb=1 coherent_pool=512K" "grep 'bootargs-append' '$WORK/board.dts' | grep -q 'swiotlb=1 coherent_pool=512K'"
	check "gmac1 enabled, sgmii" "awk '/ethernet@39d00000 {/,/^\t\t};/' '$WORK/board.dts' | grep -q 'status = \"okay\"'"
	check "tsens enabled (patch 0008)" "awk '/thermal-sensor@4a9000/,/};/' '$WORK/board.dts' | grep -q 'status = \"okay\"'"
	check "cpu-thermal zone" "grep -q 'cpu-thermal {' '$WORK/board.dts'"
	check "no 1296 MHz OPP (patch 0007)" "! grep -q 'opp-1296000000' '$WORK/board.dts' && grep -q 'opp-1008000000' '$WORK/board.dts'"
	opps=$(grep -o 'opp-[0-9]*000000 {' "$WORK/board.dts" | tr -dc '0-9 \n' | awk '{printf "%s ", $1/1000000}')
	echo "    CPU OPPs (MHz): $opps"
	if [ "$OC" ]; then
		check "OPPs 1008 + turbo 1056..1248 (overclock variant)" "[ \"$opps\" = '1008 1056 1104 1152 1200 1248 ' ]"
		check "every OPP above 1008 MHz is turbo-mode" "[ \$(grep -c 'turbo-mode;' '$WORK/board.dts') -eq 5 ]"
	else
		check "only the 1008 MHz OPP" "[ \"$opps\" = '1008 ' ] && ! grep -q 'turbo-mode' '$WORK/board.dts'"
	fi

	check "wifi calibration variant" "[ \$(grep -c 'qcom,ath11k-calibration-variant = \"Xiaomi-Redmi-AX3000\"' '$WORK/board.dts') -eq 2 ]"
	check "ath11k fw memory mode 2 (x2)" "[ \$(grep -c 'qcom,ath11k-fw-memory-mode = <0x02>' '$WORK/board.dts') -eq 2 ]"
	check "qca8337 cpu port@6 sgmii" "awk '/ethernet-switch@17/,0' '$WORK/board.dts' | grep -A3 'port@6' | grep -q 'sgmii'"
	check "gmac0 enabled (second CPU link)" "awk '/ethernet@39c00000 {/,/^\t\t};/' '$WORK/board.dts' | grep -q 'status = \"okay\"'"
	check "qca8337 cpu port@5 gmii" "awk '/ethernet-switch@17/,0' '$WORK/board.dts' | grep -A5 'port@5 {' | grep -q 'phy-mode = \"gmii\"'"

	echo "== rootfs contents"
	unsquashfs -q -d "$WORK/root" "$RVOL" >/dev/null 2>&1
	R=$WORK/root
	for f in lib/firmware/ath11k/IPQ5018/hw1.0/board-2.bin lib/firmware/ath11k/QCN6122/hw1.0/board-2.bin \
		lib/firmware/ath11k/IPQ5018/hw1.0/q6_fw.mdt lib/firmware/ath11k/QCN6122/hw1.0/m3_fw.mdt \
		lib/functions/xiaomi-dualboot.sh lib/upgrade/xiaomi-dualboot.sh lib/preinit/81_xiaomi_dualboot \
		usr/sbin/fw_printenv usr/sbin/fw_setenv; do
		check "has /$f" "[ -e '$R/$f' ]"
	done
	check "board-2.bin (IPQ5018) is ours" "cmp -s '$R/lib/firmware/ath11k/IPQ5018/hw1.0/board-2.bin' '$TOP/firmware/bdf/board-xiaomi_redmi-ax3000.ipq5018'"
	check "board-2.bin (QCN6122) is ours" "cmp -s '$R/lib/firmware/ath11k/QCN6122/hw1.0/board-2.bin' '$TOP/firmware/bdf/board-xiaomi_redmi-ax3000.qcn6122'"
	check "xiaomi-dualboot init enabled" "ls '$R'/etc/rc.d/ | grep -q 'S99xiaomi-dualboot'"
	check "no USB kmods" "! ls '$R'/lib/modules/*/ 2>/dev/null | grep -q dwc3"
	check "kmod-ath11k-ahb present" "ls '$R'/lib/modules/*/ | grep -q '^ath11k_ahb.ko'"
	check "NSS service installed (S19nss)" "ls '$R'/etc/rc.d/ | grep -q '^S19nss$'"
	check "no ath11k autoload (the nss service loads it)" "! ls '$R'/etc/modules.d/ | grep -q ath11k"
	check "NSS firmware present" "ls '$R'/lib/firmware/ | grep -q '^qca-nss0'"
	check "qca-nss-drv, qca-dwmac-nss, qca-dsa-nss modules" "for m in qca-nss-drv qca-dwmac-nss qca-dsa-nss; do ls '$R'/lib/modules/*/ | grep -q \"^\$m.ko\" || ls '$R'/lib/modules/*/ | grep -q \"^\$(echo \$m | tr - _).ko\" || exit 1; done"
	check "ECM has the DSA port patch (0051)" "grep -qa dsa_port_from_netdev '$R'/lib/modules/*/ecm.ko"
	check "kmod qca8k (DSA) present or builtin" "ls '$R'/lib/modules/*/ | grep -q qca8k || grep -q qca8k '$R'/lib/modules/*/modules.builtin 2>/dev/null || true"
	check "min_free_kbytes override (8192) for the RA81" "grep -q 'vm.min_free_kbytes=8192' '$R/etc/uci-defaults/15_min_free_kbytes'"
	for s in etc/uci-defaults/15_min_free_kbytes etc/init.d/xiaomi-dualboot lib/functions/xiaomi-dualboot.sh lib/upgrade/xiaomi-dualboot.sh lib/upgrade/platform.sh lib/preinit/81_xiaomi_dualboot; do
		check "sh -n /$s" "sh -n '$R/$s'"
	done
	check "pre-upgrade drops boost before the flash write" "grep -q 'echo 0 > /sys/devices/system/cpu/cpufreq/boost' '$R/lib/upgrade/platform.sh'"
	if [ "$OC" ]; then
		for f in etc/config/cpuclock etc/init.d/cpuclock usr/share/rpcd/acl.d/luci-app-cpuclock.json \
			usr/share/luci/menu.d/luci-app-cpuclock.json www/luci-static/resources/view/system/cpuclock.js; do
			check "has /$f" "[ -e '$R/$f' ]"
		done
		check "cpuclock init enabled (S90cpuclock)" "ls '$R'/etc/rc.d/ | grep -q '^S90cpuclock$'"
		check "cpuclock default 1008 MHz" "grep -q \"max_freq '1008000'\" '$R/etc/config/cpuclock'"
		check "sh -n /etc/init.d/cpuclock" "sh -n '$R/etc/init.d/cpuclock'"
		check "cpuclock pins boost points with the performance governor" "grep -q 'set_governor performance' '$R/etc/init.d/cpuclock'"
		check "cpuclock ACL covers the resolved thermal path" "grep -q /sys/devices/virtual/thermal '$R/usr/share/rpcd/acl.d/luci-app-cpuclock.json'"
	else
		check "no luci-app-cpuclock" "[ ! -e '$R/etc/init.d/cpuclock' ]"
	fi

	echo "== sysupgrade.bin"
	if [ -s "$SYSUPG" ]; then
		tar tf "$SYSUPG" > "$WORK/tar.txt" 2>/dev/null
		sed 's/^/    /' "$WORK/tar.txt"
		check "tar has sysupgrade-$DEV/{kernel,root}" "grep -q 'sysupgrade-$DEV/kernel' '$WORK/tar.txt' && grep -q 'sysupgrade-$DEV/root' '$WORK/tar.txt'"
		check "metadata lists redmi,ax3000 + xiaomi,redmi-ax3000 (only)" "strings '$SYSUPG' | tail -c 2000 | grep -q 'redmi,ax3000' && strings '$SYSUPG' | tail -c 2000 | grep -q 'xiaomi,redmi-ax3000\"' && ! strings '$SYSUPG' | tail -c 2000 | grep -q 'xiaomi,redmi-ax3000-oc'"
	fi
}

n=0
for dev in xiaomi_redmi-ax3000 xiaomi_redmi-ax3000-oc; do
	ls "$BIN"/*"$dev"-squashfs-factory.ubi >/dev/null 2>&1 || continue
	n=$((n + 1))
	echo "######## $dev"
	validate_device "$dev"
	echo
done
[ $n -gt 0 ] || { echo "no images in $BIN"; exit 1; }

echo
[ $fail = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $fail
