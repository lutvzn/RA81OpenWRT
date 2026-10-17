#!/bin/bash
# Export the commits on top of the base ref (patches/BASE) in the build tree
# to patches/.
#
#   scripts/export-patches.sh
#
# Development workflow: edit and commit in the build tree (SRC and BRANCH in
# patches/BASE, created by scripts/build.sh), run this script, commit patches/
# here.
# scripts/build.sh then sees that the tree matches patches/ and keeps it as is.
#
# Environment: SRC, OPENWRT_REF (defaults from patches/BASE).
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
base() { sed -n "s/^$1=//p" "$TOP/patches/BASE"; }
SRC=${SRC:-$(base SRC)}
case "$SRC" in /*) ;; *) SRC=$TOP/$SRC ;; esac
OPENWRT_REF=${OPENWRT_REF:-$(base OPENWRT_REF)}

cd "$SRC"
if ! git diff --quiet HEAD -- ||
	[ -n "$(git ls-files --others --exclude-standard -- target package)" ]; then
	echo "$SRC has uncommitted changes; commit them first" >&2
	exit 1
fi
if [ -z "$(git rev-list "$OPENWRT_REF"..HEAD)" ]; then
	echo "No commits on top of $OPENWRT_REF in $SRC" >&2
	exit 1
fi

rm -f "$TOP"/patches/*.patch
git format-patch -q --binary --zero-commit -o "$TOP/patches" "$OPENWRT_REF"..HEAD
ls "$TOP"/patches/*.patch
