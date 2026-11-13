# OpenWrt with NSS offload for the Xiaomi Redmi AX3000 (RA81)

Patches, configuration and scripts to build OpenWrt **with Qualcomm NSS hardware
offload** (target `qualcommax/ipq50xx`, Linux 6.18, arm64) for the **Xiaomi Redmi
AX3000, model RA81**.

> **Branches.** This is **`snapshot-nss`**, the release line. It is built on
> [kuncy7/openwrt-nss-edma](https://github.com/kuncy7/openwrt-nss-edma) (OpenWrt main,
> i.e. a snapshot, plus NSS offload for the IPQ5018 family).
> [`25.12-no-nss`](https://github.com/lutvzn/RA81OpenWRT/tree/25.12-no-nss) is the same device port on the stable
> OpenWrt 25.12.5 release, without NSS: all routing and Wi-Fi bridging there run on
> the CPU (about 400-470 Mbit/s Wi-Fi, CPU-bound). Branch names follow
> `<OpenWrt base>-<nss|no-nss>`.

Upstream OpenWrt does not support the device, and the NSS fork supports it only with a
modified bootloader (`xiaomi_redmi-ax3000-ubootmod`, single rootfs). This repository adds it for the **stock** Xiaomi
bootloader, with its dual-boot slots, as a small patch series on top of a pinned fork
release (`patches/BASE`). It does not contain a copy of OpenWrt: the build
script clones the base and applies the patches.

> **Only for the RA81 (label "Redmi AX3000").** Not for the AX3000T, RA82, CR880x or
> other models. Flashing third-party firmware can brick your device; read the
> install and recovery sections first.

## Status

Tested on one RA81 unit (2026-10 to 2026-11), as an access point and as a router.

| Feature | Status |
|---|---|
| Boot from the stock Xiaomi U-Boot (no bootloader change) | ✅ |
| Dual-boot A/B install and `sysupgrade` with automatic rollback | ✅ |
| Ethernet: 3x LAN + WAN (QCA8337, DSA, two CPU links) with factory MACs | ✅ |
| Wi-Fi 2.4 GHz (IPQ5000) and 5 GHz (QCN6102), ath11k with NSS Wi-Fi offload | ✅ (AP mode, both bands) |
| NSS offload: routing/NAT (ECM), bridging, Wi-Fi | ✅ |
| Wired NAT, LAN client <-> WAN | ✅ 922-930 Mbit/s both ways, CPU 98 % idle |
| Wi-Fi 5 GHz HE80, one 2x2 client | ✅ ~750-830 Mbit/s down, ~660-770 up, CPU ~97 % idle |
| Temperature sensors (4 thermal zones, hwmon) | ✅ 62-64 C idle, 77 C under full load |
| LEDs (status, internet) | ✅ |
| Kernel module repository (`apk add kmod-…`) per release | ✅ locally; published by CI |
| Buttons (reset, mesh) | ⚠️ driver bound, not press-tested |
| PPPoE WAN | ⚠️ not tested (should be offloaded by the NSS PPPoE manager) |

Stress-tested before release: 30 min of full-rate Wi-Fi downlink plus a RAM tester on the
router (0 errors), a 2 h soak with LuCI polling (no memory leak), 20x `wifi reload`,
reboots, port flaps and sysupgrades in both directions.

Hardware: Qualcomm IPQ5000 (IPQ5018 family, 2x Cortex-A53 at 1008 MHz), 256 MiB RAM,
128 MiB GigaDevice SPI-NAND, QCA8337 switch, QCN6102 5 GHz radio.

## Images: standard and overclock

Each build produces two sets of images for the same board:

| Name in the file | CPU clock |
|---|---|
| `xiaomi_redmi-ax3000` | fixed at the rated **1008 MHz**. **Recommended**; this is the image that was stress-tested for hours. |
| `xiaomi_redmi-ax3000-oc` | 1008 MHz by default. 1056, 1104, 1152, 1200 or 1248 MHz can be chosen in LuCI under **System → CPU Clock** |

An overclock runs the CPU at the chosen clock all the time (performance governor; the
kernel's schedutil governor cannot use these extra clocks). At 1008 MHz the image
behaves like the standard one. The choice is kept across reboots and sysupgrade until
it is changed again. From the shell:

```sh
uci set cpuclock.main.max_freq=1104000; uci commit cpuclock; service cpuclock reload
```

Both images use the same board name, so `sysupgrade` works between them in either
direction. The standard image ignores the setting.

> **Overclocking is at your own risk.** The IPQ5000 is rated for 1008 MHz, and the board
> has no CPU voltage regulator: every clock runs at the same 1.1 V. On the one unit
> tested, under network load plus a RAM tester, 1104 to 1248 MHz ran 15 minutes
> without an error. 1272 MHz flipped a bit in RAM after 6 minutes, and 1296 MHz reset
> the board within seconds. Your chip may fail at a lower clock. An unstable clock
> rarely crashes right away. It silently corrupts memory under load (packets, files,
> configuration), then the kernel oopses or the router resets. Above 1200 MHz there
> was no margin left. With NSS offload, routing and Wi-Fi barely use the CPU, so a
> higher clock only helps CPU-bound work (VPN, SQM without NSS, LuCI).
>
> The kernel, failsafe mode and the sysupgrade flash write always run at 1008 MHz. If
> an overclock makes the router unstable, set it back to 1008 MHz in LuCI or with the
> command above (in failsafe mode: `mount_root` first), or switch to the other boot slot.

The base fork itself runs the IPQ5000 at up to 1296 MHz. On the RA81 that corrupted
memory under load (patch `0007` below), so neither image uses it.

## What the patches do

| Patch | Content |
|---|---|
| `0001` | Device support: device tree (NSS GMAC1 + UNIPHY SGMII to the QCA8337, Q6 memory-mode-2 layout), image recipe, network/LED setup, Wi-Fi calibration from `0:ART`, board data files, U-Boot env access, Xiaomi dual-boot sysupgrade with boot confirmation |
| `0002` | Reverts the fork's NSS bring-up debug aids (`STRICT_DEVMEM` back on) |
| `0003` | `vm.min_free_kbytes` 8192 instead of 16384: ~8 MB more usable RAM |
| `0004` | Before the sysupgrade flash write: unload Wi-Fi and drop caches (~50 → ~108 MB free), so sysupgrade works with Wi-Fi up |
| `0005` | Second CPU link (GMAC0 → switch port 5) for WAN, so LAN and WAN traffic use separate links |
| `0006` | Turns off ECM's fraglist GRO on the ports |
| `0007` | CPU at the rated 1008 MHz only (the fork's 1296 MHz point corrupts memory on this board) |
| `0008` | Temperature sensor (TSENS) on |
| `0009` | The overclock image (`xiaomi_redmi-ax3000-oc`) and `luci-app-cpuclock` |

Base: `patches/BASE` (kuncy7/openwrt-nss-edma, release `ipq50xx-2026.11.11`); feeds
pinned to that release's build info in `configs/feeds.conf`. Details, measurements and
the reasons behind each patch: [`docs/nss-evaluation.md`](docs/nss-evaluation.md).

## Building

Requirements: a Linux host with the
[OpenWrt build prerequisites](https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem),
~20 GB of disk space and network access. Use the distribution's Python (the build
script puts `/usr/bin` first in `PATH`). Builds are tested on Oracle Linux 10 and on
Ubuntu 26.04 (GitHub Actions). A first build takes about 1–2.5 hours (it builds the
toolchain); later builds take minutes.

```sh
git clone https://github.com/lutvzn/RA81OpenWRT ra81-openwrt
cd ra81-openwrt
scripts/build.sh                 # generic image: 192.168.1.1, DHCP server on LAN
```

The images are copied to `out/<base label>-<revision>-c<config id>/`:

| File | Use |
|---|---|
| `*-squashfs-factory.ubi` | first install into a dual-boot slot |
| `*-squashfs-sysupgrade.bin` | upgrades from this firmware |
| `*-initramfs-uImage.itb` | RAM boot via U-Boot TFTP (needs UART) |
| `packages/` | this build's package repository (kernel modules etc., see below) |
| `sha256sums` | checksums |

Options:

```sh
scripts/build.sh -j 8                         # parallel jobs
scripts/build.sh --files configs/files-ap     # add a first-boot overlay (see below)
scripts/build.sh --repo URL                   # the image lists URL/packages.adb as its package repository
scripts/build.sh --clean                      # discard local changes and unexported commits in the build tree
scripts/build.sh --update-feeds               # refresh feed sources and installed packages
SRC=/path/to/tree DL_DIR=/path/to/dl scripts/build.sh   # other source / download dirs
```

`configs/ra81.config` selects the two devices, LuCI, the NSS packages and the initramfs
image. Edit it to add packages. Each build copies it to `.config` in the tree, so
changes made with `make menuconfig` in the tree are overwritten: save them back with
`./scripts/diffconfig.sh` (drop the `CONFIG_DEVEL`/`CONFIG_CCACHE*` lines the build script adds).
Packages selected `=m` are not in the images but in the package repository.

### Faster repeat builds

- Keep the same `SRC` tree: OpenWrt reuses its host tools, toolchain and compiled
  packages. `--clean` resets the source/patches and refreshes feeds; it does not
  remove build directories or shared caches.
- Feeds are pinned (`configs/feeds.conf`) and installed on the first build, then
  reused. Changing the feed configuration or reapplying the patch series triggers a
  refresh; `--update-feeds` forces one.
- OpenWrt's built-in **ccache** is enabled by default, with a shared 10 GB cache at
  `build/ccache`. Override with `CCACHE_DIR=/path/to/cache` and
  `CCACHE_MAXSIZE=20G`; use `USE_CCACHE=0 scripts/build.sh` to disable it.
- When the kernel configuration changes (e.g. a kmod added to `configs/ra81.config`),
  the build script also rebuilds the out-of-tree kernel modules (NSS, ECM, Wi-Fi),
  which OpenWrt itself does not. A module built against the old kernel layout can crash
  the router at boot.
- To build both variants locally, run `scripts/build.sh` followed by
  `scripts/build.sh --files configs/files-ap` in the same tree. The second build
  reuses compiled packages and regenerates the images with the overlay.
- Jobs default to `nproc`; use `-j N` to tune parallelism for available RAM/CPUs.

`tools/test-build.sh` tests the wrapper's cache/refresh, overlay and module-rebuild
behaviour with local Git/Make fixtures, without compiling firmware or accessing the
network.

### Changing the firmware (development)

`scripts/build.sh` is also the development build: there is no separate setup. The
tree it creates, `build/openwrt-nss`, is on branch `ra81-nss` (the base from
`patches/BASE` + one commit per patch). To change the firmware:

```sh
scripts/build.sh                                 # creates build/openwrt-nss (once)
cd build/openwrt-nss                             # edit target/, package/ ...
git commit -a -m "qualcommax: ipq50xx: redmi-ax3000: ..."
cd ../..
scripts/build.sh                                 # builds the tree with your commits
scripts/export-patches.sh                        # writes patches/*.patch
git add patches && git commit
```

While `patches/` is unchanged, the build uses the tree as it is, including commits
that have not been exported yet. When `patches/` changes (e.g. after `git pull`), the
tree is reset to the base and the series is re-applied, unless that would discard
commits that are not in `patches/`: then the build stops and asks you to export them
or to use `--clean`. A tree that already matches `patches/` (as after
`export-patches.sh`) is kept as it is.

### Building on GitHub Actions

If you fork or push this repository to GitHub, go to **Actions → Build firmware → Run
workflow**. It builds the generic images only; the access-point profile below is for
local builds (`--files`). The job:

1. runs `scripts/build.sh` on an Ubuntu 26.04 runner, like the base tree's own CI (a
   cold build takes about 1.5–2.5 hours; downloaded sources and compiler results are
   cached between runs);
2. runs `tools/validate-images.sh` and `tools/test-dualboot.sh` and fails if any check
   fails;
3. uploads `out/` as a workflow artifact;
4. **publishes a GitHub Release** (tag `ra81-<base label>-run<N>`) with the images and
   a combined `sha256sums`, and the build's package repository on the `gh-pages` branch
   under the same tag, which the image lists. Enable GitHub Pages for `gh-pages` after
   the first release. Untick "Publish the images as a GitHub Release" to skip this
   step.

### Access-point profile (example)

`configs/files-ap` is an example first-boot overlay that turns the router into a plain
access point on an existing LAN: static `10.0.0.3/23`, gateway/DNS `10.0.0.1`, no DHCP
or RA server, WAN port bridged into the LAN, `192.168.1.1/24` as a management alias.
Edit the addresses in `configs/files-ap/etc/uci-defaults/99-ra81-ap-network` before
using it. This matters if the router's uplink is plugged into a LAN port: a generic
image would otherwise start a second DHCP server on that network.

The overlay also puts `wan` on the LAN CPU link (`eth1`). If you bridge the WAN port
into `br-lan` yourself on a generic image, do the same (a `config device` with
`option name 'wan'` and `option conduit 'eth1'` in `/etc/config/network`): with WAN on
its own CPU link, every broadcast and multicast frame from the uplink reaches the
bridge twice.

### Checking the output

```sh
python3 -m venv build/venv-tools && build/venv-tools/bin/pip install ubi_reader
tools/validate-images.sh        # static checks: UBI volumes, FIT, DTB, NSS nodes, OPPs, rootfs, sysupgrade tar
tools/test-dualboot.sh          # simulates the dual-boot protocol against a model of U-Boot
```

`validate-images.sh` also needs `dtc` and `unsquashfs` (squashfs-tools).

## How booting works (dual boot)

The stock U-Boot boots the `kernel` UBI volume from one of two 36 MiB partitions,
`rootfs` (slot 0) or `rootfs_1` (slot 1), selected by `flag_*` variables in its
environment. The algorithm was taken from a disassembly of the RA81 bootloader:

- When `flag_ota_reboot=1`, it tries the other slot. If `flag_boot_success` is `0` at
  that point, the previous attempt failed and it **rolls back**.
- If an image cannot be loaded at all, it marks that slot as failed and falls back.

This firmware arms `flag_boot_success=0` early in boot (preinit, before Wi-Fi loads)
and confirms the slot once boot has completed. Installs and upgrades always write the
**slot that is not running**, so the previous system stays as a fallback.

- **New system crashes or hangs after early boot:** power-cycle the router and it comes
  back on the previous slot.
- **Switch slots manually:** `fw_setenv flag_last_success <0|1>; fw_setenv flag_ota_reboot 0; reboot`.
- **Limitation:** a kernel that hangs *before* preinit is retried indefinitely; use the
  recovery below.

## Installing

You need a root shell on the router that has `ubiformat` and `fw_setenv`, for example
an existing OpenWrt/ImmortalWrt build for the RA81, or an image from the
[`25.12-no-nss`](https://github.com/lutvzn/RA81OpenWRT/tree/25.12-no-nss) branch. From such a system:

```sh
cat out/<dir>/*-xiaomi_redmi-ax3000-squashfs-factory.ubi | ssh root@<router> 'cat > /tmp/f.ubi'
cat scripts/ra81-install-slot.sh | ssh root@<router> 'cat > /tmp/ra81-install-slot.sh'
ssh root@<router> sh /tmp/ra81-install-slot.sh /tmp/f.ubi <sha256>          # dry run
ssh root@<router> sh /tmp/ra81-install-slot.sh --yes --reboot /tmp/f.ubi <sha256>
```

The script checks the model, the running slot and the image. It writes only the
inactive slot, verifies the UBI volumes and arms a one-time trial boot. It never
touches the bootloader, `0:ART` (calibration and MACs) or the running slot.

From the **stock Xiaomi firmware**, first get SSH access (e.g. with
[XMiR-Patcher](https://github.com/openwrt-xiaomi/xmir-patcher)) or a UART console. The
UART route is described in the hzyitc README (`flash rootfs_1` from U-Boot). Neither
route from stock has been tested with this build.

**Before anything else, back up all MTD partitions**, especially `0:ART`. It holds the
unit's Wi-Fi calibration and MAC addresses and cannot be recreated:

```sh
ssh root@<router> cat /proc/mtd      # 22 partitions (mtd0..mtd21) on the RA81
for i in $(seq 0 21); do ssh root@<router> "cat /dev/mtd$i" > mtd$i.bin; done
```

The images ship without a root password (OpenWrt default): set one with `passwd` or in
LuCI right after the first boot.

### Upgrading

Copy `*-sysupgrade.bin` to `/tmp` on the router and run `sysupgrade` (or use LuCI); it
writes the other slot. Wi-Fi does not have to be stopped: before the flash write the
firmware unloads it and frees ~50 MB more RAM. If the router is short of memory even
for the upload, stop Wi-Fi first (`wifi down; sync; echo 3 > /proc/sys/vm/drop_caches`).

### Installing packages

Kernel modules only load on the kernel they were built for, so `kmod-*` packages from
downloads.openwrt.org do not work on this firmware. Each release publishes its own
package repository (kernel modules such as WireGuard, tun, GRE, VXLAN, L2TP, bonding,
cake, NFS/CIFS, and `luci-app-nss`) and the image already lists it:

```sh
apk update && apk add kmod-wireguard
```

Userspace packages come from the official OpenWrt snapshot feeds, also listed in
`/etc/apk/repositories.d/distfeeds.list`. Locally built images list no own repository
unless built with `--repo`; `apk add --repository /path/to/out/<dir>/packages/packages.adb`
works with a copy of `packages/` on the router.

## Recovery

1. **Other slot:** power-cycle after a failed boot, or `fw_setenv flag_last_success <slot>`.
2. **Stock TFTP recovery:** the bootloader is never modified. Hold reset while powering
   on until the system LED blinks; U-Boot then fetches the stock firmware over TFTP
   (Xiaomi's MIWIFIRepairTool or any DHCP+TFTP server;
   `miwifi_ra81_firmware_1dd69c_1.0.33.bin` from Xiaomi's download site).
3. **UART** (GPIO 28/29, 115200 8N1): interrupt U-Boot to TFTP-boot the initramfs
   image or flash a slot.

## Known limitations

- **Snapshot base.** The fork tracks OpenWrt main, not a stable release. Userspace
  packages come from the moving snapshot feeds and can, rarely, depend on a newer
  library than the image has. Kernel modules come from the release's own repository.
- **Bufferbloat at full Wi-Fi rate.** With NSS Wi-Fi offload the downlink saturates the
  firmware's TX queue: under full load, latency to the router rises to ~60-120 ms, and
  in simultaneous up/download the downlink starves the uplink. The offloaded path
  bypasses mac80211's fq_codel/AQL. `uci set nss.general.wifi_offload=0` gives host
  Wi-Fi (lower latency one way, ~500 Mbit/s, CPU saturated).
- **PPPoE** is untested on this board. The fork offloads it on other IPQ50xx boards.
- **256 MiB RAM.** Wi-Fi uses the low-memory firmware mode (max 8 interfaces / 128
  clients per radio) and the fork's 256 MB ath11k profile (smaller RX rings).
  ~50-55 MB stays available with both radios up. Monitor/sniffer mode is effectively
  unusable.
- **Set your country** in the Wi-Fi config: the board data and calibration are
  region-neutral.
- Only the RA81 with the stock bootloader is supported. CR880x variants (e.g. M79 with
  board ID 0x10) would need their own device tree / board data; the fork has its own
  `xiaomi,redmi-ax3000-ubootmod` for a modified bootloader.

## Repository layout

```
patches/            OpenWrt patch series (git format-patch) on top of patches/BASE
configs/            ra81.config (diffconfig), feeds.conf (pinned feeds),
                    distfeeds.list (the image's apk feeds), files-ap (example overlay)
scripts/build.sh    reproducible build (also the development build)
scripts/export-patches.sh      export commits in the build tree to patches/
scripts/ra81-install-slot.sh   installer for the inactive slot (runs on the router)
tools/              BDF tools, image validator, dual-boot simulation, U-Boot xref helper,
                    throughput and memory-soak benches
docs/               NSS evaluation: measurements, stress tests, decisions
.github/workflows/  manual GitHub Actions build and release (workflow_dispatch)
firmware/bdf/       Wi-Fi board data files (see firmware/bdf/README.md)
AGENTS.md           detailed development notes: hardware, findings, decisions
```

## Credits and sources

This work builds on, and took specific things from, the following projects. None of
their repositories are included here.

- **[kuncy7/openwrt-nss-edma](https://github.com/kuncy7/openwrt-nss-edma)**: the base
  tree of this line, which brings Qualcomm NSS offload (stmmac/EDMA data plane, NSS
  firmware and drivers, ECM, the `qca-8021q` DSA tagger, ath11k Wi-Fi offload, 256 MB
  memory profiles) to the IPQ5018 family on a current kernel. The RA81 port follows its
  Redmi AX3000T v2 for the Q6 memory layout.
- **[OpenWrt](https://openwrt.org)**: the base system and the `qualcommax/ipq50xx`
  target. The RA81 device tree follows existing upstream boards: the Linksys MX2000
  (same MAC1 → SGMII → QCA8337 MAC6 switch topology), the I-O DATA WN-DAX3000GR
  (QCN6102 on PCIe1 as user-PD 2, firmware memory mode 2) and the Xiaomi AX6000
  (Xiaomi U-Boot environment layout, FIT boot).
- **[hzyitc/openwrt-redmi-ax3000](https://github.com/hzyitc/openwrt-redmi-ax3000)**
  (the original Redmi AX3000 port):
  - the **Wi-Fi board data files** (unmodified payloads, see `firmware/bdf/README.md`);
  - hardware mapping used as a cross-check: GPIOs, QCA8337 port and SGMII/MAC6 wiring,
    QCN6102 reset GPIO, ART calibration offsets;
  - the dual-boot upgrade idea (write the other slot, set `flag_ota_reboot`) and the
    boot-flag semantics, which we then verified against the U-Boot binary;
  - the UART/TFTP flashing instructions referenced above.
- **[kmiit/Redmi_AX3000_immortalwrt](https://github.com/kmiit/Redmi_AX3000_immortalwrt)**
  (ImmortalWrt port, incl. a 25.12 branch): used as a reference and comparison for the
  device tree, the Q6 boot arguments (PCIe1, PD 2, GPIO 27) and the ath11k
  memory-mode-2 addresses. We deliberately differ in a few places: CPU port 6 instead
  of 0, U-Boot env size 0x10000 (CRC-verified) instead of 0x40000, board data keyed by
  variant, and boot confirmation.
- **[openwrt-xiaomi/xmir-patcher](https://github.com/openwrt-xiaomi/xmir-patcher)**:
  its decompiled Xiaomi (MediaTek) U-Boot slot-selection algorithm was the starting
  point for analysing the RA81 bootloader; also the usual way to get SSH on stock
  firmware.
- **[changganqi/redmi-ax3000-ra81-openwrt-toolkit](https://github.com/changganqi/redmi-ax3000-ra81-openwrt-toolkit)**:
  RA81 flashing notes, read for background.
- **Xiaomi stock firmware 1.0.33** (`miwifi_ra81_firmware_1dd69c_1.0.33.bin`):
  analysed for board IDs, calibration offsets, the stock switch setup (two CPU links)
  and partition layout; nothing from it is redistributed.
- **qca-swiss-army-knife / OpenWrt qca-wireless**: the ath11k board-2.bin format and
  board naming conventions (`tools/bd-encode.py` reproduces `ath11k-bdencoder` output).

## License

Patches, scripts and tools: GPL-2.0 (see `LICENSE`), matching OpenWrt. The Wi-Fi board
data files in `firmware/bdf/` (and inside patch 0001) are proprietary
Xiaomi/Qualcomm data, redistributed for interoperability as OpenWrt does for other
devices.
