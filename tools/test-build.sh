#!/bin/bash
# Exercise the build wrapper with a tiny local Git/Make fixture (no downloads).
set -euo pipefail
TOP=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost
mkdir -p "$WORK"/{scripts,configs,patches,build/source/scripts}
cp "$TOP/scripts/build.sh" "$TOP/scripts/export-patches.sh" "$WORK/scripts/"
printf 'CONFIG_TEST=y\n' > "$WORK/configs/ra81.config"
printf '%s\n' '# fixture' OPENWRT_URL=https://example.invalid/openwrt.git \
	OPENWRT_REF=v25.12.5 OPENWRT_LABEL=v25.12.5 BRANCH=ra81-25.12 \
	SRC=build/unused > "$WORK/patches/BASE"
SRC=$WORK/build/source
export SRC
cd "$SRC"
git init -q
printf 'src-git test https://example.invalid/feed\n' > feeds.conf.default
cat > scripts/feeds <<'EOF'
#!/bin/bash
set -eu
echo "$*" >> feeds.log
if [ -f fail-feeds ]; then exit 1; fi
mkdir -p feeds package/feeds
EOF
cat > scripts/getver.sh <<'EOF'
#!/bin/sh
echo test
EOF
chmod +x scripts/*
cat > Makefile <<'EOF'
.PHONY: all defconfig download package/index
all:
	@echo build >> make.log
	@mkdir -p bin/targets/qualcommax/ipq50xx/packages bin/packages/arch/base
	@printf image > bin/targets/qualcommax/ipq50xx/test-xiaomi_redmi-ax3000-squashfs-factory.ubi
	@printf kmod > bin/targets/qualcommax/ipq50xx/packages/kmod-test-1.0-r1.apk
	@[ ! -f stale-kmod ] || printf kmod > bin/targets/qualcommax/ipq50xx/packages/kmod-gone-1.0-r1.apk
	@printf app > bin/packages/arch/base/app-test-1.0-r1.apk
	@printf app > bin/packages/arch/base/app-test-extra-1.0-r1.apk
	@[ ! -f vermagic-src ] || { mkdir -p build_dir/target-t/linux-t/linux-1.0 && cp vermagic-src build_dir/target-t/linux-t/linux-1.0/.vermagic; }
defconfig:
	@echo defconfig >> make.log
download:
	@echo download >> make.log
package/index:
	@echo index >> make.log
package/%/clean:
	@echo "clean $@" >> make.log
EOF
git add .
git commit -qm base
git tag v25.12.5
printf patched > device
# Generate real patches so reset/git-am logic is exercised too. The second one
# stands in for a later patches/ update (e.g. git pull).
git add device
git commit -qm device
printf extra > extra
git add extra
git commit -qm extra
git format-patch -q -o "$WORK/spare" v25.12.5..HEAD
mv "$WORK/spare/0001-device.patch" "$WORK/patches/"
git reset -q --hard v25.12.5

run() { "$WORK/scripts/build.sh" "$@" > "$WORK/build.log" 2>&1; }
# out/ directory of a build with the current configs: <label> [repo URL]
outdir() {
	local id
	id=$( { cat "$WORK/configs/ra81.config"
		[ ! -f "$WORK/configs/distfeeds.list" ] || cat "$WORK/configs/distfeeds.list"
		echo "${2:-}"; } | sha256sum | cut -c1-8)
	echo "$WORK/out/$1-test-c$id"
}
expect_updates() {
	local count
	count=$(grep -c '^update -a$' feeds.log)
	[ "$count" = "$1" ] || { echo "Expected $1 feed updates, got $count"; exit 1; }
}
run
expect_updates 1
grep -q '^CONFIG_CCACHE=y$' .config
grep -q "CONFIG_CCACHE_DIR=\"$WORK/build/ccache\"" .config
[ -s "$(outdir v25.12.5)/sha256sums" ]
run
expect_updates 1
run --update-feeds
expect_updates 2
printf '# changed\n' >> feeds.conf.default
run
expect_updates 3
rm -rf package/feeds
run
expect_updates 4
# A failed refresh must invalidate the stamp and be retried next time.
touch fail-feeds
if run --update-feeds; then echo 'Failed feeds unexpectedly succeeded'; exit 1; fi
[ ! -e .ra81-feeds-stamp ]
rm fail-feeds
run
expect_updates 6
mkdir -p "$WORK/configs/files-ap/etc"
printf overlay > "$WORK/configs/files-ap/etc/test"
run --files "$WORK/configs/files-ap"
[ -f files/etc/test ]
[ -s "$(outdir v25.12.5)-files-ap/sha256sums" ]
run
[ ! -e files ]
USE_CCACHE=0 run
if grep -q '^CONFIG_CCACHE=y$' .config; then echo 'ccache disable failed'; exit 1; fi
if run -j 0; then echo 'Invalid job count accepted'; exit 1; fi
# Restore tracked feed config so --clean tests only the explicit reset path.
git checkout -- feeds.conf.default
run --clean
expect_updates 7

# Package repository: =m packages outside the target directory are added and
# indexed; out/ gets a copy; configs/distfeeds.list becomes the image's list.
P=bin/targets/qualcommax/ipq50xx/packages
printf 'CONFIG_TEST=y\nCONFIG_PACKAGE_kmod-test=m\n' > "$WORK/configs/ra81.config"
run
[ -f "$(outdir v25.12.5)/packages/kmod-test-1.0-r1.apk" ]
[ ! -e "$P/app-test-1.0-r1.apk" ] && ! grep -q index make.log
printf 'CONFIG_TEST=y\nCONFIG_PACKAGE_kmod-test=m\nCONFIG_PACKAGE_app-test=m\n' \
	> "$WORK/configs/ra81.config"
run
[ -f "$P/app-test-1.0-r1.apk" ] && [ ! -e "$P/app-test-extra-1.0-r1.apk" ]
grep -q index make.log
[ -f "$(outdir v25.12.5)/packages/app-test-1.0-r1.apk" ]
# A kmod the config no longer selects is dropped from the repository.
touch stale-kmod
run
rm stale-kmod
[ ! -e "$P/kmod-gone-1.0-r1.apk" ] && [ -f "$P/kmod-test-1.0-r1.apk" ]
[ ! -e "$(outdir v25.12.5)/packages/kmod-gone-1.0-r1.apk" ]
# A config change gets its own out/ directory; the earlier one is kept.
first=$(outdir v25.12.5)
printf '# changed\n' >> "$WORK/configs/ra81.config"
run
[ -s "$(outdir v25.12.5)/sha256sums" ] && [ "$(outdir v25.12.5)" != "$first" ]
[ -s "$first/sha256sums" ]
printf '# feeds\n@REPO@\nhttps://example.invalid/base/packages.adb\n' \
	> "$WORK/configs/distfeeds.list"
L=files/etc/apk/repositories.d/distfeeds.list
run
[ "$(cat "$L")" = "$(printf '# feeds\nhttps://example.invalid/base/packages.adb')" ]
run --repo 'https://example.invalid/r&a/tag/' --files "$WORK/configs/files-ap"
[ "$(sed -n 2p "$L")" = 'https://example.invalid/r&a/tag/packages.adb' ]
[ -f files/etc/test ]
rm "$WORK/configs/distfeeds.list"
printf 'CONFIG_TEST=y\n' > "$WORK/configs/ra81.config"

# Development: the tree is on a branch; local commits build as they are.
[ "$(git symbolic-ref --short HEAD)" = ra81-25.12 ]
[ "$(cat device)" = patched ]
printf dev > device
git commit -qam dev
run
[ "$(cat device)" = dev ]
# A patches/ update never discards unexported commits.
cp "$WORK/spare/0002-extra.patch" "$WORK/patches/"
if run; then echo 'Unexported commit discarded'; exit 1; fi
grep -q export-patches "$WORK/build.log"
[ "$(cat device)" = dev ]
rm "$WORK/patches/0002-extra.patch"
# After exporting, the tree matches patches/ and is kept (no re-apply/refresh).
"$WORK/scripts/export-patches.sh" > /dev/null
[ -f "$WORK/patches/0002-dev.patch" ]
head=$(git rev-parse HEAD)
run
grep -q 'already matches patches/' "$WORK/build.log"
[ "$(git rev-parse HEAD)" = "$head" ]
expect_updates 7
# A patches/ update on an untouched tree is applied.
cp "$WORK/spare/0002-extra.patch" "$WORK/patches/"
run
[ "$(cat device)" = dev ] && [ -f extra ]
expect_updates 8
# A base given as a commit id: same tree, so nothing is re-applied.
head=$(git rev-parse HEAD)
OPENWRT_REF=$(git rev-parse v25.12.5) OPENWRT_LABEL=byid run
grep -q 'already matches patches/' "$WORK/build.log"
[ "$(git rev-parse HEAD)" = "$head" ]
[ -s "$(outdir byid)/sha256sums" ]
# Pinned feeds in configs/feeds.conf replace the tree's and refresh the feeds.
printf 'src-git test https://example.invalid/feed^0123\n' > "$WORK/configs/feeds.conf"
run
cmp -s feeds.conf "$WORK/configs/feeds.conf"
expect_updates 9
run
expect_updates 9
# Out-of-tree kmod packages are cleaned and rebuilt when the kernel's vermagic
# changes; in-tree ones (package/kernel/linux) and unselected ones are not.
mkdir -p tmp
printf '%s\n' 'Source-Makefile: package/feeds/nss/foo/Makefile' 'Package: kmod-foo' '' \
	'Source-Makefile: package/feeds/nss/bar/Makefile' 'Package: kmod-bar' '' \
	'Source-Makefile: package/kernel/linux/Makefile' 'Package: kmod-intree' > tmp/.packageinfo
printf 'CONFIG_TEST=y\nCONFIG_PACKAGE_kmod-foo=y\nCONFIG_PACKAGE_kmod-intree=m\n' > "$WORK/configs/ra81.config"
builds() { grep -c '^build$' make.log; }
printf A > vermagic-src
rm -f .ra81-vermagic
: > make.log
run
[ "$(builds)" = 1 ] && ! grep -q '^clean' make.log && [ "$(cat .ra81-vermagic)" = A ]
: > make.log
run
[ "$(builds)" = 1 ] && ! grep -q '^clean' make.log
printf B > vermagic-src
: > make.log
run
[ "$(builds)" = 2 ] && [ "$(grep '^clean' make.log)" = 'clean package/feeds/nss/foo/clean' ]
[ "$(cat .ra81-vermagic)" = B ]
# A tree built before .ra81-vermagic existed is cleaned once.
rm .ra81-vermagic
: > make.log
run
[ "$(builds)" = 2 ] && grep -q '^clean package/feeds/nss/foo/clean$' make.log
: > make.log
run
[ "$(builds)" = 1 ]
rm -rf tmp build_dir vermagic-src .ra81-vermagic

printf 'PASS: build wrapper caching, refresh failure, overlays, clean reset, package repository, feed list, kmod rebuild on kernel change, dev workflow, base ref, pinned feeds and options\n'
