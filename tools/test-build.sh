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
.PHONY: all defconfig download
all:
	@echo build >> make.log
	@mkdir -p bin/targets/qualcommax/ipq50xx
	@printf image > bin/targets/qualcommax/ipq50xx/test-xiaomi_redmi-ax3000-squashfs-factory.ubi
defconfig:
	@echo defconfig >> make.log
download:
	@echo download >> make.log
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
expect_updates() {
	local count
	count=$(grep -c '^update -a$' feeds.log)
	[ "$count" = "$1" ] || { echo "Expected $1 feed updates, got $count"; exit 1; }
}
run
expect_updates 1
grep -q '^CONFIG_CCACHE=y$' .config
grep -q "CONFIG_CCACHE_DIR=\"$WORK/build/ccache\"" .config
[ -s "$WORK/out/v25.12.5-test/sha256sums" ]
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
[ -s "$WORK/out/v25.12.5-test-files-ap/sha256sums" ]
run
[ ! -e files ]
USE_CCACHE=0 run
if grep -q '^CONFIG_CCACHE=y$' .config; then echo 'ccache disable failed'; exit 1; fi
if run -j 0; then echo 'Invalid job count accepted'; exit 1; fi
# Restore tracked feed config so --clean tests only the explicit reset path.
git checkout -- feeds.conf.default
run --clean
expect_updates 7

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
[ -s "$WORK/out/byid-test/sha256sums" ]
# Pinned feeds in configs/feeds.conf replace the tree's and refresh the feeds.
printf 'src-git test https://example.invalid/feed^0123\n' > "$WORK/configs/feeds.conf"
run
cmp -s feeds.conf "$WORK/configs/feeds.conf"
expect_updates 9
run
expect_updates 9
printf 'PASS: build wrapper caching, refresh failure, overlays, clean reset, dev workflow, base ref, pinned feeds and options\n'
