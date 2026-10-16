#!/bin/bash
# Reproducible build of OpenWrt 25.12 for the Xiaomi Redmi AX3000 (RA81).
#
#   scripts/build.sh [-j N] [--clean] [--files DIR]
#
# --files DIR  overlay copied into the image root (OpenWrt "files/"), e.g.
#              configs/files-ap for the 10.0.0.3 access-point profile.
#
# Creates/updates $SRC (default build/openwrt, a checkout of the pinned OpenWrt
# tag), applies patches/*.patch, installs the feeds, applies configs/ra81.config
# and builds. Results are copied to out/<tag>-<revision>/ with sha256sums.
#
# Environment: OPENWRT_URL, OPENWRT_TAG, SRC (source dir), DL_DIR (shared
# download cache, default build/dl).
set -euo pipefail

# Parse the whole script before running it, so editing it mid-build is safe.
{

TOP=$(cd "$(dirname "$0")/.." && pwd)
OPENWRT_URL=${OPENWRT_URL:-https://git.openwrt.org/openwrt/openwrt.git}
OPENWRT_TAG=${OPENWRT_TAG:-v25.12.5}
SRC=${SRC:-$TOP/build/openwrt}
DL_DIR=${DL_DIR:-$TOP/build/dl}
JOBS=$(nproc)
CLEAN=
FILES=

while [ $# -gt 0 ]; do
	case "$1" in
	-j) JOBS=$2; shift ;;
	-j*) JOBS=${1#-j} ;;
	--clean) CLEAN=1 ;;
	--files) FILES=$(cd "$2" && pwd); shift ;;
	*) echo "usage: $0 [-j N] [--clean] [--files DIR]" >&2; exit 2 ;;
	esac
	shift
done

# OpenWrt host tools misbehave with very new Pythons from Homebrew & co.;
# prefer the distribution's tools.
export PATH=/usr/lib64/ccache:/usr/bin:/usr/sbin:/bin:$PATH

if [ ! -d "$SRC/.git" ] && [ ! -f "$SRC/.git" ]; then
	git clone "$OPENWRT_URL" "$SRC"
fi

cd "$SRC"
STAMP=$( (echo "$OPENWRT_TAG"; cat "$TOP"/patches/*.patch) | sha256sum | cut -d' ' -f1)
if [ "$(cat .ra81-stamp 2>/dev/null)" != "$STAMP" ] || [ -n "$CLEAN" ]; then
	if [ -z "$CLEAN" ] && { ! git diff --quiet HEAD -- ||
		[ -n "$(git ls-files --others --exclude-standard -- target package)" ]; }; then
		echo "$SRC has uncommitted changes; commit/export them or use --clean" >&2
		exit 1
	fi
	echo ">>> Resetting $SRC to $OPENWRT_TAG and applying patches"
	git fetch --tags origin "$OPENWRT_TAG" 2>/dev/null || true
	git checkout -q --detach "$OPENWRT_TAG"
	git reset -q --hard "$OPENWRT_TAG"
	git clean -q -fd -- target package
	git -c user.name=ra81-build -c user.email=ra81-build@localhost \
		am -q --keep-cr "$TOP"/patches/*.patch
	echo "$STAMP" > .ra81-stamp
fi

mkdir -p "$DL_DIR"
[ -e dl ] || ln -s "$DL_DIR" dl

./scripts/feeds update -a
./scripts/feeds install -a

rm -rf files
[ -n "$FILES" ] && cp -a "$FILES" files

cp "$TOP/configs/ra81.config" .config
make defconfig

make -j"$JOBS" download
make -j"$JOBS" || make -j1 V=s

VERSION=$(./scripts/getver.sh 2>/dev/null || echo unknown)
OUT=$TOP/out/$OPENWRT_TAG-$VERSION${FILES:+-$(basename "$FILES")}
mkdir -p "$OUT"
BIN=bin/targets/qualcommax/ipq50xx
cp "$BIN"/*xiaomi_redmi-ax3000* "$BIN"/*.manifest "$BIN"/profiles.json "$OUT"/ 2>/dev/null || true
cp .config "$OUT/config.full"
(cd "$OUT" && sha256sum *xiaomi_redmi-ax3000* > sha256sums)
echo ">>> Images in $OUT"
ls -la "$OUT"
exit 0
}
