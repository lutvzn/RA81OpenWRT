# NSS offload evaluation (2026-10-16)

Goal: the firmware is meant for public release, so RA81 owners will run it as their
main router (NAT, gigabit WAN), not only as a bridged AP. Throughput close to 1 Gbit
on WAN<->LAN and good Wi-Fi<->LAN throughput are release requirements.

## Source looked at

`references/openwrt-nss-edma/` = https://github.com/kuncy7/openwrt-nss-edma: NSS
offload for IPQ5018 on the **upstream `stmmac` / `dwmac-ipq5018`** Ethernet driver
(no `qca-nss-dp`, no `qca-ssdk`), kernel **6.18.55**, OpenWrt main of 2026-10-09 plus
~475 commits. Companion feed: `kuncy7/nss-packages`, branch `ipq50xx-rebase`
(qca-nss-drv, ECM, NSS qdiscs, firmware 12.2-156 / 12.5-210). Docs:
`README.ipq50xx.md` in that tree (bring-up order, topologies, 256 MB boards).

| Branch | Kernel | Verdict |
|---|---|---|
| `c3po-tag-8021q` (default, active) | 6.18.55 | **Use this one.** Has everything `ipq50xx-rebase` had plus the `dsa` topology: `qca8k` stays bound and switches to the `qca-8021q` tagger, so `lan1..3`/`wan` stay DSA ports. No per-board table needed. Run by testers on the Linksys MX2000 (same MAC1→SGMII→QCA8337 port 6 wiring as the RA81). Contains the 256 MB work and the Xiaomi AX3000T v2 (closest sibling board). |
| `ipq50xx-rebase` | 6.18 | Frozen 2026-09-17. Trunk topology only (`qca8k` unbound, `qca8337-nss` re-arms the switch, `eth0.1`/`eth0.2` + VTU map). Loses the DSA ports. |
| `ipq50xx-nss`, `julius-archive/*` | 6.18 / 7.3 | Archives. |
| `ax55-*` | 6.12 / 6.18 | Archer AX55 specific. |

## Why it cannot be applied to the 25.12.5 tree

The core of the work is `kmod-qca-dwmac-nss` (implements the `nss-dp` API that
`qca-nss-drv` expects) on top of the stmmac data-plane claim patch
`patches-6.18/0956-net-stmmac-add-a-data-plane-claim-API-for-the-NSS-firmware.patch`.
OpenWrt 25.12 has no stmmac for ipq50xx at all (it uses `qca-nss-dp` + `qca-ssdk` on
6.12); main dropped those for ipq50xx. The tagger, clock (`0090` gpll0, `0192`
ubi0 core clock), Q6 (`0828`) and ath11k NSS fixes are all against 6.18/main.
Backporting = redoing the port. Only 6.12 alternative mentioned upstream: ADCDS's
AX3000T port (`qca-nss-dp`, 6.12), not examined; it would still hit the "Atheros
header vs ECM on DSA ports" problem that only the 6.18 8021q tagger solves.

## Measurements on the RA81 (25.12.5 r33051, slot 1, ring-shrink image)

Client: this host's MT7921 (2x2 HE), test AP `RA81-iperf` on 5 GHz ch36 HE80, link
1200/720 Mbit/s (HE-MCS 11/7 NSS 2), -24 dBm. iperf3 **server on the router**
(router terminates TCP, so this is pessimistic vs. forwarding). 20 s runs.

| Test | Default (all IRQs on CPU0) | QCN6102 IRQs moved to CPU1 |
|---|---|---|
| upload, 1 stream | 397 Mbit/s, CPU0 softirq 79 % | 408 |
| download, 1 stream | 389, CPU0 softirq 81 %, CPU1 sys 88 % | 442 |
| upload, 4 streams | 466, CPU0 softirq 92 % | 468 |
| download, 4 streams | 310, **CPU0 softirq 99 %, CPU1 87 % idle** | 443 (both cores ~100 %) |

- Every data IRQ lands on CPU0: QCN6102 `DP_EXT_IRQ` (IRQ 68/73/74), its copy engines
  `ce1`/`ce2` (64/65), and `nss-dp-gmac` (42). NET_RX softirq: 77552 on CPU0 vs 144 on
  CPU1 during a run. Moving 64/65/68-74 to CPU1 (`echo 1 > /proc/irq/N/smp_affinity_list`)
  gave +43 % on 4-stream download. Runtime only, not persisted.
- Not measured yet: Wi-Fi→LAN forwarding (needs an iperf3 server on another wired
  host) and WAN↔LAN NAT (needs a WAN-side host).
- Conclusion: the CPU (2x A53 @ 1.0 GHz) is the bottleneck, not the radio. Gigabit
  NAT on these cores needs NSS.

## Findings that correct earlier assumptions

1. **Stock uses two SoC↔switch links.** `build/stockfw/rootfs/etc/config/network`:
   switch1 VLAN 1 = ports `1 2 3 6` (LAN, port 6 = SGMII → GMAC1 = `eth1`),
   VLAN 2 = ports `4 5` (WAN port + port 5 = PHY4 back-to-back with the IPQ internal
   GE PHY → GMAC0 = `eth0`); `wan` = `eth0`, `lan` = `eth1`. The hzyitc QSDK firmware
   did the same (`nss-dp 39c00000.dp1 eth0: PHY Link up speed: 1000`). Our build
   leaves GMAC0 unused and runs WAN+LAN over one 1G link, which caps routed
   throughput at ~911 Mbit/s even with offload (README.ipq50xx.md, "single CPU port
   ceiling"). Risk: the NSS README says this exact wiring (GMAC0 into switch port 5)
   has dead RX on mainline on the Redmi AX5400 (openwrt#24696), and its `dsa` setup
   consolidates such boards onto one link.
2. **The hzyitc QSDK 21.02 firmware did run NSS** on this unit: `hwinfo/dmesg.txt` has
   `nss core 0 booted successfully` (DDR 0x40000000-0x40800000), `ECM init complete`,
   `wlan0: Created a NSS virtual interface`. Whether traffic was accelerated was not
   checked. Stock/vendor DT reserves `nss@40000000` 0x800000 (8 MiB).

## Plan

1. **Bench first.** Host NIC `eno1` (Intel I219, unplugged) → RA81 WAN port, put it in
   a network namespace as the "internet" (needs sudo), iperf3 server there. Gives real
   WAN→LAN, LAN→WAN and Wi-Fi→WAN numbers from one machine. Also need a wired LAN-side
   server for Wi-Fi→LAN forwarding in the AP role. Record the 25.12 baseline (with and
   without IRQ split / RPS / software flow offloading).
2. **Port the RA81 onto `c3po-tag-8021q`** in a separate line (pin the tree commit and
   the `nss` feed commit; `feeds.conf.default` follows a branch):
   - Patch 0001: DTS moves to `target/linux/qualcommax/dts/`; replace `&dp2` with
     `&gmac1` + `&uniphy0` as in main's `ipq5018-mx2000.dts`; add
     `#include "ipq5018-nss.dtsi"` and `&nss_region { reg = <0x0 0x40000000 0x0 0x800000>; }`;
     `swiotlb=1 coherent_pool=512K` (safe with `0828`); QCN6122 user-PD regions and
     memory mode 2 as in `ipq5018-mi-router-ax3000t-v2.dts`. Keep dual-boot, BDFs,
     image recipe (main's `xiaomi_ipq50xx_ax_base` uses UbiFit; our dual-boot flow is
     our own).
   - Add the RA81 to `ATH11K_MEM_PROFILE_256M` defaults in
     `package/kernel/mac80211/ath.mk` (then `rm -rf tmp/info`) and to
     `NSS_MEM_PROFILE_LOW` in the feed's `qca-nss-drv`.
   - Patches 0002/0003 (DT ring sizes): re-evaluate; with Wi-Fi offload the rings come
     from the ath11k NSS patches / 256M profile (`DP_RXDMA_BUF_RING_SIZE` 512).
   - `.config`: `nss-tools-dwmac` as `=y` (not `=m`), firmware 12.5 + matching
     `qca-nss-drv`, `ath11k-firmware-ipq5018-qcn6122`; after changing ath.mk
     conditionals `make package/kernel/mac80211/clean`.
   - `scripts/build.sh` assumes a release tag in `patches/BASE`; adapt to a pinned SHA
     of the fork + pinned feed.
   - Install into the inactive slot with `ra81-install-slot.sh`; the 25.12 image stays
     as fallback. Checks: `ls /etc/rc.d | grep S19nss`, `logread -e nss` ends with
     "NSS wired plane + ECM up", `ls /etc/modules.d/ath11k*` must be empty,
     `cat /sys/kernel/debug/qca-dwmac-nss/status`, `nft list flowtables` empty.
   - Memory budget: now ~48-57 MB available with the AP up; NSS costs 8 MiB reserved +
     ~13-18 MB of NSS skbs (`drv_nss_skb_count` x 4 KiB). EX511 v2 (same SoC class,
     256 MB) ended at ~20 MB available after a load run.
3. **Then try the second link** (GMAC0 → GE PHY → QCA8337 port 5 for WAN) on the NSS
   tree, watching for the openwrt#24696 RX problem.
4. For the 25.12 line meanwhile: persist the IRQ split (QCN6102 IRQs on CPU1), test
   RPS and software flow offloading in the router (generic) image.

## Port status (branch `nss-6.18` of this repo)

Step 2 of the plan, started 2026-10-16:

- Base pinned to the fork's release `ipq50xx-2026.10.15-2` (`dff118f852`) rather
  than the branch tip: the 74 commits after it are an OpenWrt main merge, another
  board and LuCI/status tweaks, nothing on the IPQ5018 NSS path, and the release is a
  tree + feed combination testers have run. Feeds pinned to its
  `feeds-256m.buildinfo` (`configs/feeds.conf`).
- `scripts/build.sh` / `export-patches.sh` take URL, ref (tag or commit id), label,
  dev tree and branch from `patches/BASE`; `tools/test-build.sh` covers a commit-id
  base and pinned feeds.
- Patch 0001 = the 25.12 device patch, ported: DTS moved to
  `target/linux/qualcommax/dts/`, `&dp2`/`&switch` (qca-nss-dp/ssdk) replaced by
  `&gmac1` + `&uniphy0` (25 MHz ref, as the MX2000), `#include "ipq5018-nss.dtsi"`,
  `&nss_region` 8 MiB, `swiotlb=1 coherent_pool=512K`, Q6 on the 6.18 binding
  (`qcom,rproc = <&q6v5_wcss>`, BDF at the start of each radio's `q6-region`, no
  `qcom,bdf-addr`) with the AX3000T v2 mode-2 layout (QCN6122 BDF at 0x4d200000, not
  the vendor's 0x4d100000: the firmware is told the address over QMI), BDFs in
  `ipq-wifi/files/`. Dual boot, LEDs, caldata, env unchanged.
- Patch 0002 reverts the fork's debug-aids commit (`STRICT_DEVMEM` off).
- 25.12 patches 0002/0003 (DT ring sizes) dropped: `ATH11K_MEM_PROFILE_256M` gives
  512 RX buffers (we had 2048) and 128 monitor descriptors.
- Config = the fork's release groups common + 256m (12.5 firmware, NSS LOW, ath11k
  256M, Wi-Fi offload, PPPoE manager, NSS SQM off by default). The optional
  `ATH11K_NSS_MEM_PROFILE_256M` is left off as in the published 256m images.
- `tools/validate-images.sh` checks the NSS DT nodes, the Q6 regions, `S19nss`, no
  ath11k autoload, NSS firmware/modules and ECM's DSA patch.

## State left on the router (10.0.0.3) on 2026-10-16

- Test AP: `wireless.default_radio1` = `RA81-iperf`, psk2+ccmp, enabled, radio1
  enabled (committed). Original config saved at `/tmp/wireless.bak` (lost on reboot).
  Restore: `cp /tmp/wireless.bak /etc/config/wireless; wifi`, or set
  `wireless.default_radio1.disabled=1` and restore ssid/encryption.
- `iperf3` installed in the slot-1 overlay (`apk del iperf3`), server running (`-D`).
- IRQ 64/65/68-74 affinity set to CPU1 (until reboot).
- This host's `wlp2s0` was moved to `RA81-iperf`; back with `sudo nmcli con up APT22`.
- iperf3 installed on this host via Homebrew.
