# OpenWrt 25.12 for the Xiaomi Redmi AX3000 (RA81)

Patches, configuration and scripts to build **upstream OpenWrt 25.12.5** (target
`qualcommax/ipq50xx`, Linux 6.12, arm64) for the **Xiaomi Redmi AX3000, model RA81**.

The device is not supported by upstream OpenWrt. This repository adds it on top of the
official v25.12.5 tag with a small patch series. It does not contain a copy of OpenWrt:
the build script clones OpenWrt and applies the patches.

> **Only for the RA81 (label "Redmi AX3000").** Not for the AX3000T, RA82, CR880x or
> other models. Flashing third-party firmware can brick your device; read the
> install and recovery sections first.

## Status

Tested on one RA81 unit (2026-10).

| Feature | Status |
|---|---|
| Boot from the stock Xiaomi U-Boot (no bootloader change) | ✅ |
| Dual-boot A/B install and `sysupgrade` with automatic rollback | ✅ |
| Ethernet: 3x LAN + WAN (QCA8337 via SGMII, DSA) with factory MACs | ✅ |
| Wi-Fi 2.4 GHz (IPQ5000) and 5 GHz (QCN6102), ath11k | ✅ (AP mode, both bands) |
| LEDs (status, internet) | ✅ |
| Buttons (reset, mesh) | ⚠️ driver bound, not press-tested |
| NSS hardware offload | ❌ not available upstream for IPQ50xx |
| Temperature sensor | ❌ disabled (see limitations) |
| Wi-Fi throughput with real clients | ⚠️ not yet measured |

Hardware: Qualcomm IPQ5000 (IPQ5018 family, 2x Cortex-A53), 256 MiB RAM, 128 MiB
GigaDevice SPI-NAND, QCA8337 switch, QCN6102 5 GHz radio.

## What the patches do

| Patch | Content |
|---|---|
| `0001` | Device support: device tree, image recipe, network/LED setup, Wi-Fi calibration extraction from `0:ART`, board data files, U-Boot env access, Xiaomi dual-boot sysupgrade with boot confirmation |
| `0002` | ath11k: optional device-tree properties to shrink the host RX rings (upstream defaults unchanged) |
| `0003` | Use them on the RA81: ~35 MB more free RAM with both radios up (~48 MB vs ~17 MB available) |

Base: `patches/BASE` (OpenWrt v25.12.5).

## Building

Requirements: a Linux host with the
[OpenWrt build prerequisites](https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem),
~15 GB of disk space and network access. A first build takes about 1–2 hours (it builds
the toolchain); later builds take minutes.

```sh
git clone <this repository> ra81-openwrt
cd ra81-openwrt
scripts/build.sh                 # generic image: 192.168.1.1, DHCP server on LAN
```

The images are copied to `out/v25.12.5-<revision>/`:

| File | Use |
|---|---|
| `*-squashfs-factory.ubi` | first install into a dual-boot slot |
| `*-squashfs-sysupgrade.bin` | upgrades from this firmware |
| `*-initramfs-uImage.itb` | RAM boot via U-Boot TFTP (needs UART) |
| `sha256sums` | checksums |

Options:

```sh
scripts/build.sh -j 8                         # parallel jobs
scripts/build.sh --files configs/files-ap     # add a first-boot overlay (see below)
scripts/build.sh --clean                      # discard local changes in build/openwrt
SRC=/path/to/tree DL_DIR=/path/to/dl scripts/build.sh   # other source / download dirs
```

`configs/ra81.config` selects the device, LuCI and the initramfs image. Edit it to
add packages.

### Building on GitHub Actions

If you fork or push this repository to GitHub, go to **Actions → Build firmware → Run
workflow**. Choose the variant (`generic`, `files-ap` or `both`). The job runs
`scripts/build.sh` on an Ubuntu 24.04 runner, then runs `tools/validate-images.sh` and
`tools/test-dualboot.sh`, and uploads the `out/` directory as an artifact (images +
`sha256sums`). A cold build takes about 1.5–2.5 hours on a standard runner. Downloaded
sources are cached between runs.

### Access-point profile (example)

`configs/files-ap` is an example first-boot overlay that turns the router into a plain
access point on an existing LAN: static `10.0.0.3/23`, gateway/DNS `10.0.0.1`, no DHCP
or RA server, WAN port bridged into the LAN, `192.168.1.1/24` as a management alias.
Edit the addresses in `configs/files-ap/etc/uci-defaults/99-ra81-ap-network` before
using it. This matters if the router's uplink is plugged into a LAN port: a generic
image would otherwise start a second DHCP server on that network.

### Checking the output

```sh
python3 -m venv build/venv-tools && build/venv-tools/bin/pip install ubi_reader
tools/validate-images.sh        # static checks: UBI volumes, FIT, DTB, rootfs, sysupgrade tar
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
- **Switch slots manually:** `fw_setenv flag_last_success <0|1>; reboot`.
- **Limitation:** a kernel that hangs *before* preinit is retried indefinitely; use the
  recovery below.

## Installing

You need a root shell on the router that has `ubiformat` and `fw_setenv`, for example
an existing OpenWrt/ImmortalWrt build for the RA81. From such a system:

```sh
cat out/<version>/*-squashfs-factory.ubi | ssh root@<router> 'cat > /tmp/f.ubi'
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

### Upgrading

Copy `*-sysupgrade.bin` to `/tmp` on the router and run `sysupgrade`; it writes the
other slot. With Wi-Fi loaded,
free RAM is small while the image sits in `/tmp`, so unload Wi-Fi first:

```sh
wifi down; rmmod ath11k_ahb; rmmod ath11k; sync; echo 3 > /proc/sys/vm/drop_caches
sysupgrade /tmp/sysupgrade.bin
```

## Recovery

1. **Other slot:** power-cycle after a failed boot, or `fw_setenv flag_last_success <slot>`.
2. **Stock TFTP recovery:** the bootloader is never modified. Hold reset while powering
   on until the system LED blinks; U-Boot then fetches the stock firmware over TFTP
   (Xiaomi's MIWIFIRepairTool or any DHCP+TFTP server;
   `miwifi_ra81_firmware_1dd69c_1.0.33.bin` from Xiaomi's download site).
3. **UART** (GPIO 28/29, 115200 8N1): interrupt U-Boot to TFTP-boot the initramfs
   image or flash a slot.

## Known limitations

- **No NSS offload.** All Wi-Fi/Ethernet bridging and routing run on the CPU.
- **Temperature sensor (TSENS) disabled.** The boot firmware does not enable it on the
  IPQ5000 and some zones report bogus critical values. That would shut the board down
  early in boot, before rollback protection is armed.
- **256 MiB RAM.** Wi-Fi uses the low-memory firmware mode (max 8 interfaces / 128
  clients per radio) and smaller RX rings (patch 0003). Monitor/sniffer mode is
  effectively unusable.
- **Set your country** in the Wi-Fi config: the board data and calibration are
  region-neutral.
- Only the RA81 is supported. CR880x variants (e.g. M79 with board ID 0x10) would
  need their own device tree / board data.

## Repository layout

```
patches/            OpenWrt patch series (git format-patch) on top of patches/BASE
configs/            ra81.config (diffconfig) and files-ap (example overlay)
scripts/build.sh    reproducible build
scripts/ra81-install-slot.sh   installer for the inactive slot (runs on the router)
tools/              BDF tools, image validator, dual-boot simulation, U-Boot xref helper
.github/workflows/  manual GitHub Actions build (workflow_dispatch)
firmware/bdf/       Wi-Fi board data files (see firmware/bdf/README.md)
CLAUDE.md           detailed development notes: findings, decisions, test results
```

## Credits and sources

This work builds on, and took specific things from, the following projects. None of
their repositories are included here.

- **[OpenWrt](https://openwrt.org)**: the base system and the `qualcommax/ipq50xx`
  target. The RA81 device tree follows existing upstream boards: the Linksys MX2000
  (same MAC1 → SGMII → QCA8337 MAC6 switch topology), the I-O DATA WN-DAX3000GR
  (QCN6102 on PCIe1 as user-PD 2, firmware memory mode 2) and the Xiaomi AX6000
  (Xiaomi U-Boot environment layout, FIT boot). The ath11k DT memory-mode patch by
  Robert Marko was the model for patch 0002.
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
  device tree, the Q6 boot arguments (PCIe1, PD 2, GPIO 27), the ath11k memory-mode-2
  addresses and the report of bogus thermal readings on IPQ5000. We deliberately
  differ in a few places: CPU port 6 instead of 0, U-Boot env size 0x10000 (CRC-verified)
  instead of 0x40000, board data keyed by variant, and boot confirmation.
- **[openwrt-xiaomi/xmir-patcher](https://github.com/openwrt-xiaomi/xmir-patcher)**:
  its decompiled Xiaomi (MediaTek) U-Boot slot-selection algorithm was the starting
  point for analysing the RA81 bootloader; also the usual way to get SSH on stock
  firmware.
- **[changganqi/redmi-ax3000-ra81-openwrt-toolkit](https://github.com/changganqi/redmi-ax3000-ra81-openwrt-toolkit)**:
  RA81 flashing notes, read for background.
- **Xiaomi stock firmware 1.0.33** (`miwifi_ra81_firmware_1dd69c_1.0.33.bin`):
  analysed for board IDs, calibration offsets and partition layout; nothing from it is
  redistributed.
- **qca-swiss-army-knife / OpenWrt qca-wireless**: the ath11k board-2.bin format and
  board naming conventions (`tools/bd-encode.py` reproduces `ath11k-bdencoder` output).

## License

Patches, scripts and tools: GPL-2.0 (see `LICENSE`), matching OpenWrt. The Wi-Fi board
data files in `firmware/bdf/` (and inside patch 0001) are proprietary
Xiaomi/Qualcomm data, redistributed for interoperability as OpenWrt does for other
devices.
