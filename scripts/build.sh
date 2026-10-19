#!/bin/bash
# Reproducible build of OpenWrt for the Xiaomi Redmi AX3000 (RA81).
#
#   scripts/build.sh [-j N] [--clean] [--update-feeds] [--files DIR] [--repo URL]
#
# --files DIR  overlay copied into the image root (OpenWrt "files/"), e.g.
#              configs/files-ap for the 10.0.0.3 access-point profile.
# --repo URL   where this build's package repository will be published
#              (URL/packages.adb); the image lists it first. The repository
#              (kmods and the other =m packages) is copied to out/<dir>/packages/
#              with or without this option.
#
# Creates/updates $SRC (a clone of $OPENWRT_URL), puts the pinned ref +
# patches/*.patch on branch $BRANCH (all four from patches/BASE), installs the
# feeds (pinned in configs/feeds.conf, if present), applies configs/ra81.config
# and builds. configs/distfeeds.list, if present, becomes the image's
# /etc/apk/repositories.d/distfeeds.list (@REPO@ -> --repo, or dropped).
# Results are copied to out/<label>-<revision>-c<config id>/ with sha256sums;
# the id hashes the config, the feed list and --repo, which change the image
# without a new revision.
# The same tree is used for development: commit on the branch, then
# scripts/export-patches.sh. Unexported commits are never discarded (except
# with --clean).
#
# Environment: OPENWRT_URL, OPENWRT_REF (tag or full commit id), OPENWRT_LABEL,
# SRC (source dir), BRANCH (defaults for these five from patches/BASE),
# DL_DIR (shared download cache, default build/dl), CCACHE_DIR (default
# build/ccache), CCACHE_MAXSIZE (default 10G), USE_CCACHE (default 1; set 0
# to disable).
set -euo pipefail

# Parse the whole script before running it, so editing it mid-build is safe.
{

TOP=$(cd "$(dirname "$0")/.." && pwd)
base() { sed -n "s/^$1=//p" "$TOP/patches/BASE"; }
OPENWRT_URL=${OPENWRT_URL:-$(base OPENWRT_URL)}
OPENWRT_REF=${OPENWRT_REF:-$(base OPENWRT_REF)}
OPENWRT_LABEL=${OPENWRT_LABEL:-$(base OPENWRT_LABEL)}
OPENWRT_LABEL=${OPENWRT_LABEL:-$OPENWRT_REF}
BRANCH=${BRANCH:-$(base BRANCH)}
SRC=${SRC:-$(base SRC)}
case "$SRC" in /*) ;; *) SRC=$TOP/$SRC ;; esac
DL_DIR=${DL_DIR:-$TOP/build/dl}
JOBS=$(nproc)
CLEAN=
UPDATE_FEEDS=
FILES=
REPO=

while [ $# -gt 0 ]; do
	case "$1" in
	-j) JOBS=$2; shift ;;
	-j*) JOBS=${1#-j} ;;
	--clean) CLEAN=1 ;;
	--update-feeds) UPDATE_FEEDS=1 ;;
	--files) FILES=$(cd "$2" && pwd); shift ;;
	--repo) REPO=${2%/}; shift ;;
	*) echo "usage: $0 [-j N] [--clean] [--update-feeds] [--files DIR] [--repo URL]" >&2; exit 2 ;;
	esac
	shift
done

if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
	echo "Job count must be a positive integer" >&2
	exit 2
fi

# Resolve shared cache paths before changing into the source tree.
mkdir -p "$DL_DIR"
DL_DIR=$(cd "$DL_DIR" && pwd)
if [ "${USE_CCACHE:-1}" = 1 ]; then
	CCACHE_DIR=${CCACHE_DIR:-$TOP/build/ccache}
	mkdir -p "$CCACHE_DIR"
	CCACHE_DIR=$(cd "$CCACHE_DIR" && pwd)
	export CCACHE_DIR
	export CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-10G}
fi

# OpenWrt host tools misbehave with very new Pythons from Homebrew & co.;
# prefer the distribution's tools.
export PATH=/usr/lib64/ccache:/usr/bin:/usr/sbin:/bin:$PATH

if [ ! -d "$SRC/.git" ] && [ ! -f "$SRC/.git" ]; then
	git clone "$OPENWRT_URL" "$SRC"
fi

cd "$SRC"
# The patch series lives on branch $BRANCH, which is also where development
# happens: commit there, then scripts/export-patches.sh. .ra81-stamp holds the
# hash of ref + patches/ and the commit this script last created.
patch_ids() { git patch-id --stable | cut -d' ' -f1 | sort; }
STAMP=$( (echo "$OPENWRT_REF"; cat "$TOP"/patches/*.patch) | sha256sum | cut -d' ' -f1)
if [ "$(sed -n 1p .ra81-stamp 2>/dev/null || true)" != "$STAMP" ] || [ -n "$CLEAN" ]; then
	if [ -z "$CLEAN" ] && { ! git diff --quiet HEAD -- ||
		[ -n "$(git ls-files --others --exclude-standard -- target package)" ]; }; then
		echo "$SRC has uncommitted changes; commit/export them or use --clean" >&2
		exit 1
	fi
	if ! git rev-parse -q --verify "$OPENWRT_REF^{commit}" >/dev/null; then
		if [[ "$OPENWRT_REF" =~ ^[0-9a-f]{40}$ ]]; then
			git fetch origin "$OPENWRT_REF"
		else
			git fetch origin tag "$OPENWRT_REF"
		fi
	fi
	RECORDED=$(sed -n 2p .ra81-stamp 2>/dev/null || true)
	BRANCH_TIP=$(git rev-parse -q --verify "refs/heads/$BRANCH" || true)
	if [ -z "$CLEAN" ] && git merge-base --is-ancestor "$OPENWRT_REF" HEAD &&
		[ "$(git format-patch --binary --stdout "$OPENWRT_REF"..HEAD | patch_ids)" = \
		  "$(cat "$TOP"/patches/*.patch | patch_ids)" ]; then
		# e.g. right after scripts/export-patches.sh: nothing to re-apply.
		echo ">>> $SRC already matches patches/"
	elif [ -n "$CLEAN" ] || [ -z "$BRANCH_TIP" ] || [ "$BRANCH_TIP" = "$RECORDED" ]; then
		echo ">>> Resetting $SRC to $OPENWRT_REF and applying patches"
		git checkout -q -f -B "$BRANCH" "$OPENWRT_REF"
		git clean -q -fd -- target package
		git -c user.name=ra81-build -c user.email=ra81-build@localhost \
			am -q --keep-cr "$TOP"/patches/*.patch
		rm -f .ra81-feeds-stamp
	else
		echo "Branch $BRANCH in $SRC has commits that are not in patches/." >&2
		echo "Export them with scripts/export-patches.sh, or discard them with --clean." >&2
		exit 1
	fi
	printf '%s\n%s\n' "$STAMP" "$(git rev-parse HEAD)" > .ra81-stamp
fi

[ -e dl ] || ln -s "$DL_DIR" dl

# Feed updates are network-heavy and can change package revisions. Reuse the
# installed feeds until the source/feed configuration changes or refresh is asked
# for explicitly. Write the stamp only after both commands succeed.
[ -f "$TOP/configs/feeds.conf" ] && cp "$TOP/configs/feeds.conf" feeds.conf
FEEDS_CONFIG=feeds.conf
[ -f "$FEEDS_CONFIG" ] || FEEDS_CONFIG=feeds.conf.default
FEEDS_STAMP=$(sha256sum "$FEEDS_CONFIG" | cut -d' ' -f1)
if [ -n "$UPDATE_FEEDS" ] || [ ! -d feeds ] || [ ! -d package/feeds ] ||
	[ "$(cat .ra81-feeds-stamp 2>/dev/null)" != "$FEEDS_STAMP" ]; then
	rm -f .ra81-feeds-stamp
	./scripts/feeds update -a
	./scripts/feeds install -a
	echo "$FEEDS_STAMP" > .ra81-feeds-stamp
else
	echo ">>> Reusing installed feeds (use --update-feeds to refresh)"
fi

rm -rf files
[ -n "$FILES" ] && cp -a "$FILES" files
if [ -f "$TOP/configs/distfeeds.list" ]; then
	mkdir -p files/etc/apk/repositories.d
	if [ -n "$REPO" ]; then
		sed "s|^@REPO@\$|$(printf '%s' "$REPO" | sed 's/[&|\\]/\\&/g')/packages.adb|" \
			"$TOP/configs/distfeeds.list"
	else
		sed '/^@REPO@$/d' "$TOP/configs/distfeeds.list"
	fi > files/etc/apk/repositories.d/distfeeds.list
fi

cp "$TOP/configs/ra81.config" .config
if [ "${USE_CCACHE:-1}" = 1 ]; then
	# OpenWrt builds its own ccache; no host ccache package is required.
	printf '\nCONFIG_CCACHE=y\nCONFIG_CCACHE_DIR="%s"\n' "$CCACHE_DIR" >> .config
fi
make defconfig

make -j"$JOBS" download
# Kernel modules built outside the kernel tree (mac80211 backports, NSS, ...)
# are not rebuilt when only the kernel configuration changes, e.g. after an
# =m kmod adds kernel options: they keep the old struct layouts (a new
# CONFIG_NET_UDP_TUNNEL shifts struct net) and crash at load. .ra81-vermagic
# records the kernel they were built against; on a change, clean them and
# build again. A tree built before this check is cleaned once.
vermagic() { cat build_dir/target-*/linux-*/linux-[0-9]*/.vermagic 2>/dev/null || true; }
BUILT_FOR=$(cat .ra81-vermagic 2>/dev/null || true)
[ -n "$BUILT_FOR" ] || [ -z "$(vermagic)" ] || BUILT_FOR=unknown
make -j"$JOBS" || make -j1 V=s
if [ -n "$BUILT_FOR" ] && [ "$(vermagic)" != "$BUILT_FOR" ]; then
	echo ">>> Kernel configuration changed: rebuilding the out-of-tree kernel modules"
	for dir in $(awk '/^Source-Makefile:/ { mk = $2 }
		/^Package: kmod-/ { print $2, mk }' tmp/.packageinfo |
		while read -r pkg mk; do
			case "$mk" in package/kernel/linux/*) continue ;; esac
			grep -qxE "CONFIG_PACKAGE_$pkg=[ym]" .config && dirname "$mk"
		done | sort -u); do
		make "$dir/clean"
	done
	make -j"$JOBS" || make -j1 V=s
fi
vermagic > .ra81-vermagic

# The target repository holds the kmods. bin/ is not cleaned between builds:
# drop kmods the config no longer selects (built for an earlier kernel, they
# would not install on this one), add the other =m packages (built into the
# feed directories, which are not published) and index it again.
BIN=bin/targets/qualcommax/ipq50xx
changed=
for f in "$BIN"/packages/kmod-*.apk; do
	[ -f "$f" ] || continue
	pkg=$(basename "$f" .apk)
	pkg=${pkg%-r[0-9]*}
	pkg=${pkg%-*}
	grep -qxF -e "CONFIG_PACKAGE_$pkg=y" -e "CONFIG_PACKAGE_$pkg=m" .config && continue
	rm -f "$f"
	changed=1
done
for pkg in $(sed -n 's/^CONFIG_PACKAGE_\(.*\)=m$/\1/p' .config); do
	case "$pkg" in kmod-*) continue ;; esac
	for f in bin/packages/*/*/"$pkg"-[0-9]*.apk; do
		[ -f "$f" ] && cp "$f" "$BIN/packages/" && changed=1
	done
done
[ -z "$changed" ] || make package/index

VERSION=$(./scripts/getver.sh 2>/dev/null || echo unknown)
CFG_ID=$( { cat "$TOP/configs/ra81.config"
	[ ! -f "$TOP/configs/distfeeds.list" ] || cat "$TOP/configs/distfeeds.list"
	echo "$REPO"; } | sha256sum | cut -c1-8)
OUT=$TOP/out/$OPENWRT_LABEL-$VERSION-c$CFG_ID${FILES:+-$(basename "$FILES")}
mkdir -p "$OUT"
cp "$BIN"/*xiaomi_redmi-ax3000* "$BIN"/*.manifest "$BIN"/profiles.json "$OUT"/ 2>/dev/null || true
cp .config "$OUT/config.full"
(cd "$OUT" && sha256sum -- *xiaomi_redmi-ax3000* > sha256sums)
rm -rf "$OUT/packages"
[ ! -d "$BIN/packages" ] || cp -a "$BIN/packages" "$OUT/packages"
echo ">>> Images in $OUT"
ls -la "$OUT"
exit 0
}
