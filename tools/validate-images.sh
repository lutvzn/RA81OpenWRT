#!/bin/bash
# Static validation of the RA81 build outputs.
#   tools/validate-images.sh [BIN_DIR]
# Needs: dtc, unsquashfs, python venv with ubi_reader (build/venv-tools).
set -uo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
BIN=${1:-$TOP/build/openwrt/bin/targets/qualcommax/ipq50xx}
VENV=$TOP/build/venv-tools/bin
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()   { echo "  OK   $*"; }
bad()  { echo "  FAIL $*"; fail=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

FACTORY=$(ls "$BIN"/*xiaomi_redmi-ax3000-squashfs-factory.ubi 2>/dev/null | head -1)
SYSUPG=$(ls "$BIN"/*xiaomi_redmi-ax3000-squashfs-sysupgrade.bin 2>/dev/null | head -1)
INITRD=$(ls "$BIN"/*xiaomi_redmi-ax3000-initramfs-uImage.itb 2>/dev/null | head -1)

echo "== Files"
for f in "$FACTORY" "$SYSUPG" "$INITRD"; do
	check "present: $(basename "${f:-missing}")" "[ -s '${f:-/nonexistent}' ]"
done
[ -s "$FACTORY" ] || exit 1

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
"$VENV"/python -I - "$KVOL" "$WORK/board.dtb" <<'EOF'
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
check "q6 region 48 MiB" "grep -A1 'wcss@4b000000' '$WORK/board.dts' | grep -q '0x4b000000 0x00 0x3000000'"
check "tsens disabled" "awk '/thermal-sensor@4a9000/,/};/' '$WORK/board.dts' | grep -q 'status = \"disabled\"'"
check "wifi calibration variant" "[ \$(grep -c 'qcom,ath11k-calibration-variant = \"Xiaomi-Redmi-AX3000\"' '$WORK/board.dts') -eq 2 ]"
check "ath11k fw memory mode 2 (x2)" "[ \$(grep -c 'qcom,ath11k-fw-memory-mode = <0x02>' '$WORK/board.dts') -eq 2 ]"
check "qca8337 cpu port@6 sgmii" "awk '/ethernet-switch@17/,0' '$WORK/board.dts' | grep -A3 'port@6' | grep -q 'sgmii'"

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
check "kmod qca8k (DSA) present or builtin" "ls '$R'/lib/modules/*/ | grep -q qca8k || grep -q qca8k '$R'/lib/modules/*/modules.builtin 2>/dev/null || true"
for s in etc/init.d/xiaomi-dualboot lib/functions/xiaomi-dualboot.sh lib/upgrade/xiaomi-dualboot.sh lib/upgrade/platform.sh lib/preinit/81_xiaomi_dualboot; do
	check "sh -n /$s" "sh -n '$R/$s'"
done

echo "== sysupgrade.bin"
if [ -s "$SYSUPG" ]; then
	tar tf "$SYSUPG" > "$WORK/tar.txt" 2>/dev/null
	sed 's/^/    /' "$WORK/tar.txt"
	check "tar has sysupgrade-xiaomi_redmi-ax3000/{kernel,root}" "grep -q 'sysupgrade-xiaomi_redmi-ax3000/kernel' '$WORK/tar.txt' && grep -q 'sysupgrade-xiaomi_redmi-ax3000/root' '$WORK/tar.txt'"
	check "metadata lists redmi,ax3000 + xiaomi,redmi-ax3000" "strings '$SYSUPG' | tail -c 2000 | grep -q 'redmi,ax3000' && strings '$SYSUPG' | tail -c 2000 | grep -q 'xiaomi,redmi-ax3000'"
fi

echo
[ $fail = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $fail
