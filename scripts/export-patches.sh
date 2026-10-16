#!/bin/bash
# Export the commits on top of the OpenWrt tag in the build tree to patches/.
#
#   scripts/export-patches.sh
#
# Development workflow: edit and commit in build/openwrt (branch ra81-25.12,
# created by scripts/build.sh), run this script, commit patches/ here.
# scripts/build.sh then sees that the tree matches patches/ and keeps it as is.
#
# Environment: SRC (default build/openwrt), OPENWRT_TAG (default v25.12.5).
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
SRC=${SRC:-$TOP/build/openwrt}
OPENWRT_TAG=${OPENWRT_TAG:-v25.12.5}

cd "$SRC"
if ! git diff --quiet HEAD -- ||
	[ -n "$(git ls-files --others --exclude-standard -- target package)" ]; then
	echo "$SRC has uncommitted changes; commit them first" >&2
	exit 1
fi
if [ -z "$(git rev-list "$OPENWRT_TAG"..HEAD)" ]; then
	echo "No commits on top of $OPENWRT_TAG in $SRC" >&2
	exit 1
fi

rm -f "$TOP"/patches/*.patch
git format-patch -q --binary --zero-commit -o "$TOP/patches" "$OPENWRT_TAG"..HEAD
ls "$TOP"/patches/*.patch
