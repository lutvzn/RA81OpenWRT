# RA81 OpenWrt — Xiaomi Redmi AX3000 (RA81) on OpenWrt 25.12

Custom OpenWrt **25.12.5** (upstream `qualcommax/ipq50xx`, Linux 6.12, arm64) for the
Xiaomi Redmi AX3000, model **RA81**. Note: there is no OpenWrt "25.10" release; the
release series is 25.12, which is what this project targets.

Everything about the device in this file was verified against the live router
(10.0.0.3), its full flash dump, the stock Xiaomi firmware or the U-Boot binary,
unless marked otherwise.

> **Branch `nss-6.18` (NSS offload line, in progress since 2026-10-16).** Here the
> base is not v25.12.5 but kuncy7/openwrt-nss-edma `c3po-tag-8021q` at release
> `ipq50xx-2026.10.15-2` (OpenWrt main, kernel 6.18, stmmac + NSS, DSA `qca-8021q`
> tagger), pinned in `patches/BASE`; feeds pinned in `configs/feeds.conf` to that
> release's `feeds-256m.buildinfo`. Dev tree `build/openwrt-nss` (worktree of
> `references/openwrt-nss-edma`), branch `ra81-nss`; outputs in
> `out/nss-2026.10.15-2-<rev>/`. Patches: 0001 = device port (DTS in
> `target/linux/qualcommax/dts/`, `gmac1`+`uniphy0`, `ipq5018-nss.dtsi`, 8 MiB
> `nss_region`, mode-2 multi-PD Q6 layout of the AX3000T v2, BDFs in
> `ipq-wifi/files/`), 0002 = revert of the fork's debug-aids commit (no
> `STRICT_DEVMEM`). The 25.12 ring-shrink patches are dropped: the fork's
> `ATH11K_MEM_PROFILE_256M` shrinks the rings further. Config = the fork's release
> groups common + 256m. Status, plan and checks: `docs/nss-evaluation.md`. The rest
> of this file describes the 25.12 line (`master`) unless it says otherwise.

## Repository layout

| Path | What | In git |
|---|---|---|
| `README.md`, `LICENSE` | user-facing docs (build/install/recovery/credits), GPL-2.0 | yes |
| `patches/` | OpenWrt patch series on top of the tree named in `patches/BASE` (URL, ref, label, dev tree, branch) | yes |
| `configs/ra81.config` | diffconfig (target, device, LuCI, initramfs) | yes |
| `configs/feeds.conf` | pinned feeds, copied into the tree (NSS line only) | yes |
| `configs/files-ap/` | optional first-boot overlay: this unit's AP role (10.0.0.3/23, no DHCP) | yes |
| `scripts/build.sh` | reproducible build, also the dev build: `patches/BASE` ref + `git am` patches on its branch, feeds, build, copy to `out/` | yes |
| `scripts/export-patches.sh` | `git format-patch` the dev tree's commits into `patches/` | yes |
| `tools/test-build.sh` | tests `build.sh`/`export-patches.sh` (stamps, feeds, overlays, dev workflow) on a local fixture | yes |
| `scripts/ra81-install-slot.sh` | on-router installer into the inactive dual-boot slot | yes |
| `firmware/bdf/` | the repacked `board-2.bin` files + provenance (`firmware/bdf/README.md`) | yes |
| `tools/bd-*.py` | board-2.bin list/extract/encode (encoder is byte-identical to ath11k-bdencoder) | yes |
| `tools/uboot-xref.py` | Thumb-2 disassembly around string xrefs in the U-Boot ELF | yes |
| `tools/validate-images.sh` | static checks of the outputs (UBI volumes, FIT config/arch, DTB, rootfs, sysupgrade tar) | yes |
| `.github/workflows/build.yml` | manual GitHub Actions build (variant: generic / files-ap / both), validates, uploads `out/` | yes |
| `tools/test-dualboot.sh` | runs the shipped dual-boot library against a modelled U-Boot (7 scenarios) | yes |
| `tools/bench-netns.sh`, `tools/bench-run.sh` | forwarding bench: wired iperf3 server in a netns on this host (sudo) + one run through the RA81 with its CPU/ECM counters | yes |
| `tools/soak-mem.sh` | memory soak logger: per-minute MemAvailable/SUnreclaim/NSS skb count CSV over SSH, optional iperf3 load | yes |
| `tools/bench-nat.sh` | router-role bench: moves `eno1` into a netns as the "internet" side (172.16.0.1, iperf3 server) | yes |
| `tools/bench-wired.sh` | wired-LAN-client NAT bench: a spare NIC in a netns runs iperf3 through the RA81 (sudo) | yes |
| `docs/nss-evaluation.md` | NSS offload evaluation, throughput measurements, port plan (2026-10-16) | yes |
| `build/openwrt` | dev/build tree on branch `ra81-25.12` (here a git worktree of `references/openwrt/`; `build.sh` clones a fresh one if missing) | no |
| `build/stockfw` | stock RA81 1.0.33 firmware + extracted rootfs | no |
| `build/ref` | qca-wireless clone, kernel source excerpts | no |
| `ra81-backup/` | **full MTD backup of this unit** (22 partitions, sha256 verified vs router) | no — private |
| `hwinfo/` | live dumps: dmesg, running DTB/DTS, sysinfo (**contains Wi-Fi key and U-Boot secrets**) | no — private |
| `out/` | build outputs | no |
| `references/openwrt/`, `references/openwrt-nss-edma/` (kuncy7 NSS fork, all branches), `openwrt-redmi-ax3000/`, `Redmi_AX3000_immortalwrt/`, `redmi-ax3000-ra81-openwrt-toolkit/`, `xmir-patcher/` | reference clones | no |

Development workflow (same as in the README, so contributors get the same tree):
edit in `build/openwrt` (branch `ra81-25.12`), commit, build with `scripts/build.sh`,
then `scripts/export-patches.sh` and commit `patches/`. Do not run `make` by hand for
images: `build.sh` also rewrites `.config` from `configs/ra81.config`, sets up
ccache/`dl`, and sets `files/` (removed unless `--files` is given). `build.sh` never
discards unexported commits on the branch (only `--clean` does); a tree whose commits
match `patches/` by patch-id is kept as is.

## Build

Host: Oracle Linux 10, 4 cores. Prereqs passed with the distro packages; use the
system Python (`/usr/bin/python3`, 3.12) — `scripts/build.sh` puts `/usr/bin` first in
`PATH` because Homebrew's Python 3.15 is first by default.

```
scripts/build.sh                            # generic image (192.168.1.1, DHCP server on LAN)
scripts/build.sh --files configs/files-ap   # this unit's AP profile (see below)
scripts/build.sh --clean                    # discard local changes/unexported commits, re-apply patches
scripts/export-patches.sh                   # dev tree commits -> patches/
tools/test-build.sh                         # wrapper tests (no compile, no network)
SRC=build/openwrt-repro OPENWRT_URL=$PWD/references/openwrt scripts/build.sh   # build in another tree
tools/validate-images.sh [bin dir]          # static validation of the outputs
tools/test-dualboot.sh                      # dual-boot protocol simulation
```

The download cache is shared in `build/dl` (`DL_DIR`). A cold build (host tools,
toolchain, kernel, packages) takes ~75 min on the 4-core host; image-only rebuilds a
few minutes.

**Variants.** The generic image boots with OpenWrt defaults: 192.168.1.1 with a DHCP
server on LAN. This unit is an access point on 10.0.0.0/23 with its uplink on a LAN
port, so a generic image would be unreachable at 10.0.0.3 *and* act as a rogue DHCP
server on that network. `configs/files-ap` (uci-defaults) reproduces the current role:
lan static 10.0.0.3/23, gw/DNS 10.0.0.1, DHCPv4/v6/RA off, WAN port bridged into
br-lan, wan/wan6 disabled, `mgmt` alias 192.168.1.1/24. Wi-Fi stays at OpenWrt
defaults (disabled); no credentials are embedded.

Manual equivalent: checkout `v25.12.5`, `git am patches/*.patch`, `./scripts/feeds update -a &&
./scripts/feeds install -a`, `cp configs/ra81.config .config && make defconfig && make`.

Outputs (`bin/targets/qualcommax/ipq50xx/`):
- `openwrt-25.12.5-...-xiaomi_redmi-ax3000-squashfs-factory.ubi` — raw UBI for a slot (first install)
- `...-squashfs-sysupgrade.bin` — sysupgrade tar (from this firmware onwards)
- `...-initramfs-uImage.itb` — RAM boot via U-Boot TFTP (needs UART)

## Hardware (verified)

| Item | Value | Source |
|---|---|---|
| SoC | Qualcomm **IPQ5000** (IPQ5018 family), 2x A53 @ up to 1 GHz, SoC v1.1 | dmesg `CPU: IPQ5000, SoC Version: 1.1` |
| RAM | 256 MiB @ 0x40000000 | dmesg cnss `memory: 40000000 268435456` |
| NAND | GigaDevice GD5F1GQ5REYIG SPI-NAND 128 MiB, 2 KiB page, 128 KiB block, 128 B OOB, QPIC ECC BCH8/512 | dmesg |
| Switch | QCA8337 (chip 0x1302) on MDIO1 addr 17 (0x11), reset GPIO 26 | live DT, dmesg |
| CPU link | IPQ MAC1 —SGMII— QCA8337 **MAC6** (vendor `PAD6_MODE = MAC6_SGMII_EN`); MAC0—GE PHY—QCA8337 PHY4/port 5 (unused by this build; **stock uses it as the WAN link**: VLAN 2 = ports 4+5 → `eth0`, see `docs/nss-evaluation.md`) | hzyitc DTS, vendor board.json, stock `/etc/config/network` |
| Ports | PHY0..2 = LAN1..3, PHY3 = WAN (QCA8337 ports 1..4) | vendor board.json/swconfig |
| Wi-Fi 2.4 | IPQ5000 internal, ath11k AHB, board ID **0x24** | ART caldata header, U-Boot `cnss2.bdf_integrated=0x24` |
| Wi-Fi 5 | QCN6102 (QCN6122 family) on PCIe1, user PD 2, reset GPIO 27, board ID **0x60** | vendor DT/cmdline |
| LEDs | GPIO17 yellow:system, GPIO19 blue:system, GPIO20 yellow:internet, GPIO22 blue:internet (active high) | live DT |
| Buttons | GPIO25 reset, GPIO23 mesh (active low) | live DT |
| UART | GPIO28/29 (`blsp0_uart1`), 115200n8 | live DT |
| U-Boot | 2016.01 (QSDK), Thumb-2 ELF at 0x4a920000, supports "Jumping to AARCH64 kernel via monitor" | APPSBL strings |

### Flash layout (SMEM partition table from MIBIB; Linux lowercases the names)

| Name | Offset | Size | Notes |
|---|---|---|---|
| 0:SBL1 … 0:CDT_1 | 0x0 | 0x480000 | boot chain, never touch |
| 0:APPSBLENV | 0x480000 | 0x80000 | U-Boot env, **env size 0x10000** (CRC verified; 0x40000 is wrong) |
| 0:APPSBL / _1 | 0x500000 / 0x640000 | 0x140000 each | U-Boot (identical copies) |
| 0:ART | 0x780000 | 0x100000 | MACs + Wi-Fi calibration — read-only |
| 0:TRAINING | 0x880000 | 0x80000 | |
| bdata | 0x900000 | 0x80000 | Xiaomi "sys" env (0x10000, CRC ok): SN, model, country… |
| crash, crash_syslog | 0x980000 | 0x80000 each | |
| **rootfs** (slot 0) | 0xa80000 | 0x2400000 (36 MiB) | UBI: kernel, rootfs, rootfs_data |
| **rootfs_1** (slot 1) | 0x2e80000 | 0x2400000 (36 MiB) | UBI |
| overlay | 0x5280000 | 0x1f00000 (31 MiB) | unused by this build |
| rsvd0 | 0x7180000 | 0x80000 | |

ART contents: `0x0` WAN MAC, `0x6` LAN MAC, `0x1000` 2.4 GHz caldata (embeds the
2.4 GHz MAC = LAN+2, board ID 0x24), `0x26800` 5 GHz caldata (MAC = LAN+1, board ID
0x60), `0x4c000` empty.

### Memory map (reserved)

Upstream ipq5018.dtsi + qcn6122.dtsi reserve tz_apps 0x4a400000 (4M), bootloader
0x4a800000 (2M), sbl 0x4aa00000 (1M), smem 0x4ab00000 (1M), tz 0x4ac00000 (2M),
Q6 0x4b000000 (48M). The vendor DT has **tz = 4 MiB**, so the RA81 DTS widens
`tz_region` to 0x400000. ath11k uses **FW memory mode 2** (vendor `tgt-mem-mode = 2`)
with the vendor mode-2 addresses: IPQ5018 BDF 0x4c400000; QCN6122 BDF 0x4d100000,
M3 dump 0x4df00000.

## Dual boot (U-Boot "bootmiwifi") — verified by disassembly

`bootmiwifi` reads `kernel` from the UBI on `rootfs` (slot 0) or `rootfs_1` (slot 1),
boots it with `bootm <addr>#config@mp02.1`-style FIT config selection and passes
`ubi.mtd=<slot> root=mtd:ubi_rootfs rootfstype=squashfs cnss2.…`. Our DTS appends
`root=/dev/ubiblock0_1`. Slot choice (function at 0x4a92232c in APPSBL):

```
s1,s2 = flag_try_sys1_failed, flag_try_sys2_failed; ota = flag_ota_reboot; last = flag_last_success
if any of them > 1:          slot 0
elif ota == 1:               slot = 1 - last
                             if flag_boot_success exists and == 0:  slot = last, clear ota  ("ota reboot failed, swap to old firmware!")
else:                        slot = last, or 1 - last if that slot's try_failed flag is set
image fails to boot  ->      flag_try_sys<slot+1>_failed = 1, flag_ota_reboot = 0, reset
```

U-Boot never writes `flag_boot_success`. Our implementation
(`/lib/functions/xiaomi-dualboot.sh`):
- **upgrade** (`sysupgrade`, or `scripts/ra81-install-slot.sh` for the first install):
  write the *inactive* slot, then set `flag_try_sys1/2_failed=0`,
  `flag_last_success=<running slot>`, unset `flag_boot_success`, `flag_ota_reboot=1`.
- **arm** (preinit `81_xiaomi_dualboot`, before kmodloader/ath11k): if `ota=1`, set `flag_boot_success=0`.
- **confirm** (`/etc/init.d/xiaomi-dualboot`, START=99): `flag_last_success=<slot>`,
  `flag_ota_reboot=0`, `flag_boot_success=1`, clear try_failed flags.

Consequences: a bad image → U-Boot falls back by itself. A system that dies after
preinit → power-cycle → rollback. A kernel that hangs before preinit → U-Boot keeps
retrying the new slot; recover with the stock TFTP recovery (see below).

Manual slot switch from a running system: `fw_setenv flag_last_success <0|1>;
fw_setenv flag_ota_reboot 0; reboot`.

## Key decisions

- **Base**: upstream OpenWrt v25.12.5 `qualcommax/ipq50xx` (6.12, NSS-DP + qca-ssdk +
  DSA qca8k). Device tree modelled on Linksys MX2000 (identical MAC1→SGMII→QCA8337 MAC6
  topology) rather than the ImmortalWrt RA81 DTS (which used QCA8337 port 0).
- **Device name** `xiaomi_redmi-ax3000`, compatible `xiaomi,redmi-ax3000`
  (`SUPPORTED_DEVICES += redmi,ax3000` for images from hzyitc/ImmortalWrt builds).
- **BDFs**: upstream ath11k firmware reports `qmi-board-id=255` for every IPQ5018/QCN6122
  board (confirmed on the device: `board_id 0xff`), so boards are distinguished by
  `variant=`. The hzyitc/ImmortalWrt board-2.bin files are keyed by board IDs 16/36/96
  (QSDK driver hack) and would not match, so we repack them as
  `bus=ahb,qmi-chip-id=0,qmi-board-id=255,variant=Xiaomi-Redmi-AX3000`.
  Payloads: hzyitc **board 36 (= 0x24)** for the IPQ5000 and **board 96 (= 0x60)** for the
  QCN6102 (provenance in `firmware/bdf/README.md`). Board ID 0x24 (not 0x10 as the hzyitc/ImmortalWrt
  PA-type heuristic picks when `wl_pa_type` is missing from bdata) is what this unit's ART
  calibration header records and what the stock U-Boot passes for every RA81.
  **The stock RA81 1.0.33 BDFs do NOT work**: they are an older template for firmware
  WLAN.HK.2.5, and the upstream firmware (WLAN.HK.2.7.0.1-01744, the same build the
  hzyitc QSDK firmware ran) asserts on them:
  `phyrf_bdf.c:6245 Assertion axis_value == ANTENNACHAIN_AXIS_Z failed` (seen on device).
- **TSENS disabled**: the boot firmware does not enable it on IPQ5000 and some zones
  report bogus critical temperatures (ImmortalWrt saw forced shutdowns). A critical
  shutdown before preinit would defeat the rollback.
- **Packages**: USB and ext4/losetup defaults removed (no USB port, NAND only); LuCI added.
- **overlay partition** (31 MiB) is left unused for now (rootfs_data lives in the slot UBI).

## Recovery paths

1. **Dual boot**: the other slot (currently slot 1, the first test image) stays
   intact; see above.
2. **Stock TFTP recovery** (bootloader untouched): hold reset and power on until the
   system LED blinks; U-Boot does DHCP/TFTP recovery (env `serverip=192.168.31.100`).
   Use Xiaomi `MIWIFIRepairTool` or any DHCP+TFTP server with the stock
   `miwifi_ra81_firmware_1dd69c_1.0.33.bin` (`build/stockfw/`, md5
   `8159117ea9fc2368282f848ed61dd69c`, official CDN URL in the hzyitc README).
3. **UART** (GPIO28/29, 115200n8): this unit already has `uart_en=1` and `boot_wait=on`,
   so U-Boot can be interrupted. From U-Boot an image can be RAM-booted
   (`tftpboot` the `initramfs-uImage.itb`, `bootm`) or written to a slot (hzyitc README):
   `tftpboot <factory.ubi>; flash rootfs_1; setenv flag_try_sys2_failed 0;
   setenv flag_boot_rootfs 1; setenv flag_last_success 1; saveenv`.
4. **Full flash backup** in `ra81-backup/` (`SHA256SUMS`, `router-md5.txt`). ART must
   never be lost: it holds the unit's calibration and MACs.

## Status

- [x] Hardware inventory, flash backup, stock firmware analysis, U-Boot dual-boot logic
- [x] Device support patch (DTS, image, network, LEDs, caldata, BDF, env, dual-boot)
- [x] Toolchain/kernel build and image generation (OpenWrt r33051-f5dae5ece4 + patch)
- [x] Static validation: `tools/validate-images.sh` all checks pass (generic and AP variant)
- [x] Dual-boot protocol simulation: `tools/test-dualboot.sh` 7/7 scenarios pass; library
      functions also run under the router's busybox ash (read-only test)
- [x] Installer dry-run on the router (all device/slot/env checks pass)
- [x] Kernel image (0x41000000..0x424b0000) does not overlap U-Boot's 0x44000000 load buffer
- [x] Clean-tree reproducibility build via `scripts/build.sh` (fresh clone, `git am`):
      same package manifest; rootfs differs only in the per-build apk signing key/db and
      `qca-ssdk.ko` (4 of 886 files). Not bit-identical because the `git am` commit date
      feeds SOURCE_DATE_EPOCH.
- [x] **On-device test (2026-10-15)**: installed into slot 1 with `ra81-install-slot.sh`
      (slot 0 = hzyitc QSDK 21.02 kept as fallback). Results below.

### On-device results (OpenWrt 25.12.5 r33051, slot 1)

| Area | Result |
|---|---|
| Boot | stock U-Boot boots the arm64 FIT (config@mp02.1); up and pingable ~40 s after reboot |
| Dual boot | preinit arm + init confirm worked: `flag_last_success=1 flag_ota_reboot=0 flag_boot_success=1` |
| Flash | smem partitions lowercased as predicted (`0:art`, `0:appsblenv`); UBI kernel 5.3M / rootfs 7.6M / rootfs_data 19M (14.8M free overlay); fw_env 0x10000 auto-configured |
| Ethernet | qca8k SGMII CPU link 1G/full on QCA8337 port 6; lan1..3 + wan; uplink on **lan1** (= vendor swconfig port 1); MACs: LAN from ART+0x6, WAN from ART+0x0; gateway reachable |
| AP profile | 10.0.0.3/23 + 192.168.1.1 alias, no DHCP server; LuCI reachable |
| Wi-Fi | with the stock-1.0.33 BDFs: Q6 assert (see above). With the WLAN.HK.2.7 BDFs (tested via overlay, now in the build): both radios up, test APs on 2.4 GHz ch1 HE20 and 5 GHz ch36 HE80 (country BR), no crashes |
| Memory | MemTotal 182 MB. 96 MB available without Wi-Fi; **~17 MB available** once ath11k has probed (allocated at probe, not per AP); stable over LuCI loads and 2x `wifi reload` (no OOM, no leak) |
| LEDs/buttons | blue/yellow status, blue/yellow wan present (WAN = netdev trigger); gpio-keys bound, GPIO 23/25 idle high; physical press not tested remotely |

**sysupgrade test (2026-10-16)**: from slot 1, `sysupgrade` (config kept) of the rebuilt
AP image wrote slot 0 and the new system confirmed itself (`flag_last_success=0`,
`flag_ota_reboot=0`, `flag_boot_success=1`): the full A/B upgrade path works on
hardware. Wi-Fi comes up with the image's own BDFs; config (network, country BR) and
the SSH host key were preserved. Before sysupgrade, unload ath11k
(`wifi down; rmmod ath11k_ahb; rmmod ath11k`) — with Wi-Fi loaded only ~5 MB is
available once the image sits in /tmp.

**Memory: ath11k DP ring shrinking (2026-10-16)**. ath11k fills, per radio at probe
time, 4096 RX buffers, 4096 monitor buffers (rxdma1 chips) and 1024 monitor status
buffers (~2.5 KB each) — ~80 MB for both radios incl. ring memory. Patch 0002 adds
`qcom,ath11k-{rx-buf,mon-buf,mon-status}-ring-size` DT properties (defaults unchanged
without them); patch 0003 sets 2048/128/512 on the RA81. Measured on device (sysupgrade
to slot 1): MemAvailable **56 MB** after boot with both radios probed (was ~21 MB),
**48 MB** with both test APs up (was ~17 MB); stable over 2x `wifi reload`, no driver
errors. Userspace is only ~4.4 MB anon, so it is not worth trimming.

**Current slots**: slot 1 = image with ring shrinking (running, default); slot 0 = the
previous rebuilt image (fixed BDFs, default rings) as fallback. The hzyitc QSDK 21.02 firmware is gone (restorable from `ra81-backup/`
mtd18 or via stock TFTP recovery).

Earlier leftovers on the router from testing (slot 1 overlay): `/lib/firmware/ath11k/{IPQ5018,QCN6122}/hw1.0/board-2.bin`
in the overlay hold the fixed BDFs (identical to the rebuilt image); `wireless.radioN.country=BR`.

### Current outputs (from the clean tree `build/openwrt-repro`)

| Dir | Variant |
|---|---|
| `out/v25.12.5-r33051-f5dae5ece4/` | generic (192.168.1.1, DHCP server) |
| `out/v25.12.5-r33051-f5dae5ece4-files-ap/` | AP profile for this unit (10.0.0.3, no DHCP) — use this for the first test |

Each has `*-squashfs-factory.ubi` (first install into a slot), `*-squashfs-sysupgrade.bin`,
`*-initramfs-uImage.itb`, manifest, `config.full` and `sha256sums`.

## Known limitations

- ath11k DP RX rings are shrunk on this board (patches 0002/0003): RX buffers 2048
  (default 4096), monitor buffers 128 (default 4096), monitor status 512 (default 1024).
  Monitor (sniffer) mode is effectively unusable; per-station RX statistics may be less
  complete under very heavy load; peak RX throughput not yet measured with a client.
  The TX completion ring (32768 entries, ~1 MB kmalloc + ~1 MB coherent per radio) is
  untouched (compile-time wrap macro).
- A kernel that hangs *before* preinit is retried forever by U-Boot (ota flag stays set);
  recovery then needs UART or the stock TFTP recovery.
- No temperature reporting (TSENS disabled).
- No NSS offload (verified on device): no NSS firmware, no qca-nss-drv/ECM; `qca_nss_dp`
  is only the GMAC Ethernet driver. Wi-Fi<->Ethernet bridging and any routing run on
  the A53 cores. Software flow offloading (nftables flowtable) is available but off
  (irrelevant for the bridged-AP role); hardware flow offload is not supported. The
  previous hzyitc QSDK firmware *did* boot the NSS core, ECM and NSS Wi-Fi interfaces
  (`hwinfo/dmesg.txt`), as stock does. Measured 2026-10-16: Wi-Fi throughput is
  CPU-bound (~390-470 Mbit/s to the router, CPU0 softirq at 99 %); NSS evaluation and
  plan in `docs/nss-evaluation.md`.
- ath11k in FW memory mode 2: max 8 vdevs / 128 peers per radio.
- RA81 only. CR880x variants (M79 uses board ID 0x10) and the hzyitc/ImmortalWrt
  `redmi,ax3000` sysupgrade path are not covered; install with `ra81-install-slot.sh`.
- Regulatory: BDFs and caldata carry regdomain 0 (world); set the country in
  `/etc/config/wireless` (the current router uses BR).

### Not verifiable without booting the hardware

Ethernet bring-up (NSS-DP + qca-ssdk + qca8k over SGMII to QCA8337 MAC6), Wi-Fi
(Q6 multi-PD with QCN6102, memory mode 2 within 256 MiB), and the stock U-Boot
handing the arm64 FIT to the kernel. All three follow upstream devices that share
these pieces (Linksys MX2000 topology, I-O DATA WN-DAX3000GR Wi-Fi setup, Xiaomi
AX6000 boot path) and the ImmortalWrt RA81 port.

## On-device test plan (needs approval: writes slot 1 = `rootfs_1` only)

```
scp out/<ver>-files-ap/*-squashfs-factory.ubi root@10.0.0.3:/tmp/f.ubi
scp scripts/ra81-install-slot.sh root@10.0.0.3:/tmp/
ssh root@10.0.0.3 sh /tmp/ra81-install-slot.sh /tmp/f.ubi <sha256>          # dry run
ssh root@10.0.0.3 sh /tmp/ra81-install-slot.sh --yes --reboot /tmp/f.ubi <sha256>
```

Then on 10.0.0.3 (or 192.168.1.1): `cat /proc/cmdline` (ubi.mtd=rootfs_1),
`fw_printenv | grep flag_` (last_success=1, ota_reboot=0, boot_success=1),
`ip -br link`, `dmesg | grep -iE 'ath11k|qca8k|nss|remoteproc|q6v5|error|fail'`,
`iw phy | grep -E 'Wiphy|MHz'`, `free`, LEDs/buttons (`logread -f` while pressing).
To go back to the old firmware: `fw_setenv flag_last_success 0; reboot`.

## Remaining tasks / ideas

- **NSS line (branch `nss-6.18`)**: ported and running on the router since
  2026-10-17 (Wi-Fi<->LAN 550-660 Mbit/s at ~97 % CPU idle, MemAvailable 52 MB).
  **Next steps** (sysupgrade memory, kmod repo, PPPoE NAT test; the 3 h soak and the NAT test (wired 922-930 Mbit/s) are done) and
  the router state left behind: `docs/nss-evaluation.md`, "To do next".

- Restore the owner's Wi-Fi (SSID/key/channel 100 HE160 from the old config) — needs OK.
- Press-test reset/mesh buttons; long-term stability with clients; throughput.
- Throughput test from a Wi-Fi client (iperf3) to confirm the 2048 RX ring is enough.
- Optional: re-enable TSENS with only cpu/ubi32 zones once readings are checked.
- Optional: use the 31 MiB `overlay` partition for rootfs_data.
- Optional: upstream submission (BDFs to qca-wireless, device patch to openwrt).

## Reference clones

- `references/openwrt/` — upstream OpenWrt (worktree source for `build/openwrt`)
- `openwrt-redmi-ax3000/` — hzyitc port (5.15 mainline branch; QSDK branches exist)
  — origin of the currently running firmware (21.02 QSDK, kernel 5.4)
- `Redmi_AX3000_immortalwrt/` — kmiit ImmortalWrt port; branch `redmi_ax3000-25.12`
  (commit 3eb8724) is a 25.12 port: uses QCA8337 port 0, env size 0x40000 (wrong),
  board_id-based BDFs, no boot confirmation script.
- `redmi-ax3000-ra81-openwrt-toolkit/` — RA81 flashing notes (Chinese) + manifests
- `xmir-patcher/` — SSH unlock for stock firmware; `activate_boot.py` documents a
  (MediaTek) Xiaomi U-Boot slot algorithm similar to ours
