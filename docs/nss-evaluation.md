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

## Port status (branch `snapshot-nss` of this repo, first named `nss-6.18`)

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

### First on-device run (2026-10-17, slot 0)

Installed with `ra81-install-slot.sh` into slot 0 (slot 1 = 25.12 ring-shrink image,
fallback) as a *trial*: the AP profile plus an overlay `/etc/init.d/xiaomi-dualboot`
that does not confirm, so any reboot would have gone back to slot 1. Confirmed by
hand after the tests below (`flag_last_success=0`).

- Boot: up ~40 s after reboot; stmmac/gmac1 SGMII link 1G to QCA8337 port 6; DSA
  ports on the `qca-8021q` tagger.
- NSS: `nss core 0 booted successfully` (DDR 0x40000000-0x40800000), `eth0` armed as
  phys_if 1 (`started`, `rs=3 ts=6`), ECM up, log ends with "NSS wired plane + ECM up
  (Wi-Fi on the NSS path)"; both radios `nss init soc` (if_num 203/215), no ath11k in
  `/etc/modules.d`, no flowtable, no kernel errors.
- Memory: MemTotal 172.9 MB (182 MB on 25.12: 8 MiB NSS region); MemAvailable 29 MB
  with both radios probed, 22.7 MB with the 5 GHz AP up, ~24 MB after the runs below
  (25.12 ring-shrink: 56 / 48 MB). Slab 42 MB (NSS pbufs). Tight but stable; the
  fork's optional `ATH11K_NSS_MEM_PROFILE_256M` is the next thing to try.
- Port labels verified: the uplink cable is in the jack marked WAN on the case and
  shows carrier on `wan` (switch port 4 / PHY3), `lan1..3` down - the same mapping as
  stock and as the 25.12 DTS. The 25.12 note "uplink on lan1" (AGENTS.md) was
  either taken with the cable in a LAN jack or is wrong; not re-checked on 25.12.

Throughput, **forwarded through the router** (bridged AP role): this host's MT7921 on
`RA81-iperf` (5 GHz ch36 HE80, -23 dBm, link 1080/648 Mbit/s) -> RA81 -> uplink ->
LAN switch -> this host's 2.5G USB NIC in a network namespace (macvlan 10.0.0.51,
`arp_ignore=1` on the NIC so replies cannot bypass the RA81). 20 s runs, router CPU
from `/proc/stat` over the run:

| Test | NSS (forwarded) | router CPU | 25.12 baseline (router-terminated) |
|---|---|---|---|
| upload, 1 stream | 404 Mbit/s | 97 % idle | 397, CPU0 softirq 79 % |
| upload, 4 streams | 425 | 97 % idle | 466, CPU0 softirq 92 % |
| download, 1 stream | 580 | 98 % idle | 389, CPU0 softirq 81 % |
| download, 4 streams | 543 | 97 % idle | 310, CPU0 softirq 99 % |

The router is no longer the bottleneck: the CPU stays ~97 % idle and the rates now
follow the client's Wi-Fi link (upload at its 648 Mbit/s TX rate). The baselines are
not the same path (25.12 was measured with the router as the endpoint, which NSS
would not accelerate); a 25.12 forwarding run on the same bench would make the
comparison exact. WAN<->LAN NAT (the router role) is not measured yet.

Cold boot (2026-10-17, power pulled ~10 s): slot 0, NSS core booted, phys_if 1
`started`, both radios on the NSS path, "NSS wired plane + ECM up", no errors. The
first WPA2 client after it (the case the fork's `0192` clock fix is about) then ran
download 4 streams 629 Mbit/s and upload 1 stream 500 Mbit/s (link 1201/865) at
97-98 % idle, NSS still up. MemAvailable 20.9 MB at 8 min, 19.1 MB after the runs
(18 min) - lower than after the warm boot (22.7-24 MB); watch for a downward trend.

### `ATH11K_NSS_MEM_PROFILE_256M` (2026-10-17, slot 1)

Enabled in `configs/ra81.config` (needs `make package/kernel/mac80211/clean`: the
option is an `ath.mk` conditional; verified `CPTCFG_ATH11K_NSS_MEM_PROFILE_256M=y` in
the backports `.config` and a rebuilt `ath11k.ko`). Installed with **sysupgrade** from
the slot-0 NSS image, config kept, after `wifi down` + `drop_caches` to make room for
the 15 MB image in /tmp (23 MB available then): slot 1 written, booted, NSS up,
self-confirmed (`flag_last_success=1`) - the A/B upgrade path works on the NSS line.
The 25.12 image that was in slot 1 is gone (slot 0 = previous NSS image, fallback).

| | without profile | with profile |
|---|---|---|
| MemAvailable, AP up after boot | 22.7 MB | 31.3 MB |
| SUnreclaim, AP up after boot | ~40 MB | 34.4 MB |
| MemAvailable after the 4 runs | 24 MB (warm boot) / 19.1 MB (cold boot) | 26.1 MB |
| SUnreclaim after the 4 runs | 40.4 MB | 41.2 MB |
| ul 1 / ul 4 / dl 1 / dl 4 (Mbit/s) | 500 / - / - / 629 (link 1201/865) | 546 / 555 / 657 / 652 (link 1201/865) |

No throughput cost, CPU 96-98 % idle. The gain shrinks under load: the slab grows back
to ~41 MB once the NSS buffer pools fill. The next lever is `vm.min_free_kbytes`
(OpenWrt sets 16384 on this board, stock 2048; MemAvailable subtracts it).

### `vm.min_free_kbytes` 16384 -> 8192 (2026-10-17, runtime only)

OpenWrt's `/etc/init.d/sysctl` sets 16384 on every board over 64 MB (the RA81 stock
firmware runs the same script; only its `kill_plugin_process.sh` drops it to 512 in
an emergency - the "stock uses 2048" in the fork's README is about another board).
Watermarks min/low/high 16/20/24 MB -> 8/10/12 MB; MemAvailable 25.1 -> 44.0 MB at
once. With the profile image (slot 1), `sysctl -w vm.min_free_kbytes=8192`:

- 3 rounds of the 4-run bench: ul 467-557, dl 649-666 Mbit/s (same as at 16384),
  CPU 88-98 % idle, MemAvailable 45-48 MB, no `page allocation failure`.
- 30 min soak, `iperf3 -P 4 --bidir` through the router: 328 Mbit/s up + 282 down at
  the same time (127.7 GB moved), MemAvailable 44.0-45.8 MB throughout, SUnreclaim
  43.8-47.0 MB (+2.5 MB in the last 5 min - watch in a longer soak), 0 allocation
  failures, 0 errors, NSS `started`, load ~0.0, station `tx failed` 0.

Made persistent in patch 0003: `/etc/uci-defaults/15_min_free_kbytes` writes
`/etc/sysctl.d/20-min-free.conf` (`vm.min_free_kbytes=8192`) on the RA81 only, at
first boot, before `/etc/init.d/sysctl` (START=11) applies sysctl.d. Installed by
sysupgrade into slot 0 (config kept; 53 MB available before copying the image):
self-confirmed, 8192 applied at boot without manual steps, NSS up, test AP up,
**MemAvailable 52.1 MB after boot with the AP up** (first NSS image 22.7 MB, with the
ath11k profile 31.3 MB; 25.12 ring-shrink image 48 MB). 4096 untested.

### 3 h soak at min_free 8192 (2026-10-17)

`tools/soak-mem.sh -d 10800 --load` (one sample per minute over SSH, `iperf3 -P 4
--bidir` Wi-Fi client -> router -> wired netns for the whole run; slot 0 image with
patch 0003): 180 samples, 457 GB up (364 Mbit/s) + 346 GB down (275 Mbit/s), 0
allocation failures, load ~0.0, CPU ~98 % idle.

| Metric | Range |
|---|---|
| MemAvailable | 39.9-49.6 MB (47.2 MB at the end) |
| SUnreclaim | 41.2-50.7 MB (43.4 MB at the end) |
| `drv_nss_skb_count` | 4381-5751, no trend |

SUnreclaim peaked at 50.7 MB in the first hour and settled at ~43-44 MB: a plateau of
the NSS pools filling, not a leak. Raw data in `build/soak/` (not in git).

### Router role: WAN<->LAN NAT (2026-10-17, slot 1, generic image)

Generic (no `--files`) image r0+37564-e8dda8ca92 plus a non-confirming overlay
`/etc/init.d/xiaomi-dualboot`, installed into slot 1 as a trial (`ra81-install-slot.sh`;
slot 0 = AP image, fallback). Default OpenWrt config: br-lan 192.168.1.1/24 + DHCP,
`wan` static 172.16.0.2/24 (gw 172.16.0.1), wan zone masquerading. Bench: LAN client =
this host's Wi-Fi `wlp2s0` on a test AP (5 GHz ch36 HE80, link 1201/865); "internet" =
`eno1` in a netns (`tools/bench-nat.sh up`, 172.16.0.1, iperf3 server) cabled to the
WAN jack. 20 s runs with `SERVER=172.16.0.1 ROUTER=192.168.1.1 tools/bench-run.sh`.

| Run (client -> NAT -> server) | Mbit/s | CPU idle (both cores) |
|---|---|---|
| ul 1 stream | 512 | 98 % |
| ul 4 streams | 622 | 98 % |
| dl 1 stream (-R) | 799 | 98 % |
| dl 4 streams (-R) | 783 | 98 % |

NAT + routing is offloaded: ECM `tcp_accelerated_count` 1 for the flow, NSS
`ipv4_rx_pkts` 6.76 M, softirq ~1 %, 0 allocation failures; MemAvailable 51 -> 45 MB
after the runs (SUnreclaim 45 MB). The Wi-Fi numbers are client-bound (CPU idle).

**Wired LAN client** (RTL8153 USB GbE in a netns, cabled to `lan1`, `tools/bench-wired.sh`;
same server, same NAT path):

| Run | Mbit/s | CPU idle (both cores) |
|---|---|---|
| ul 1 stream | 929 | 99 % |
| ul 4 streams | 922 | 98 % |
| dl 1 stream | 930 | 98 % |
| dl 4 streams | 927 | 98 % |

That is gigabit line rate for TCP goodput (~940 Mbit/s max) in both directions with the
CPUs idle: the router-role goal (~900 Mbit/s, the single-CPU-port ceiling) is met.
Not measured: PPPoE (no PPPoE server on the bench).

### Second CPU link and the bridged-WAN AP (2026-11-12, ipq50xx-2026.11.11, slot 0)

Patch 0005 enables GMAC0 -> port 5 as a second CPU port; the fork's board.d puts
`wan` on `eth0` and `lan1-3` on `eth1`, and since 2026.11.11 (fork commit
4d73bf55e2) nss-tools keeps that split. In the AP profile `wan` is bridged into
br-lan, and that breaks flooding. Patch 784 (tag_8021q VLAN only to the port's own
CPU port) covers the standalone VIDs only. The bridge VID (3088) contains both CPU
ports, and the QCA8337 runs in 802.1Q secure mode, where the VLAN table, not the port
lookup mask, decides where floods go. So every upstream broadcast/multicast went
up both links:
switch MIB p05/p06 TxBroad +41/+41 in 10 s. With no LAN port up, the eth0 copy is dropped (`dropped frame
from ... vbid=1`). With a LAN port up, tag_8021q hands it to that LAN port, so br-lan
forwards both copies and learns upstream MACs on it. A 60 s capture on a Wi-Fi client
showed every broadcast/multicast frame twice (3-5 ms apart). Unicast was unaffected
(tx_fwd_offload, the hardware FDB picks the port; 900 pings, 0 loss).

Fix for the AP role: a `config device` with `name wan`, `conduit eth1` (all ports on
one link; an AP gains nothing from the second link). `configs/files-ap` now adds it on
first boot when board.json has `wan` on `eth0`; on the router it was added by hand.
After a reboot: `wan@eth1`, fw_mask 0x2, eth0 rx +0, no dropped-frame warnings.
Wi-Fi (ch36 HE80) unchanged: dl4 826 / ul4 767 Mbit/s at 97 % idle (split: dl4 775
/ ul4 806). The router role keeps the split. Generic images with a bridged WAN, and
the fork's other split boards (AX5400, Cudy P5, PZ-L8, CR880x), have the same issue,
so it should be reported upstream (drafted in `issue.md`, not posted yet).

It is the fork's bug, not ours: patches 0001-0006 change no kernel code (the DTS,
board.d, base-files, one config symbol), and the fork's own `xiaomi,redmi-ax3000-ubootmod`
and `xiaomi,cr8806` get the same wan@eth0 / lan@eth1 split from its board.d. The CPU
rule is `dsa_port_tag_8021q_vlan_match()` (fork patch 784): a CPU port gets a VID when a
user port behind it does, so a bridge spanning both conduits puts both CPU ports in its
VID. Nothing on `c3po-tag-8021q` after the release tag changes this (checked up to
b0c52c9563, 2026-11-11). Runtime A/B, 30 s each, uplink on wan, host on lan3:
wan@eth1 p05 Tx bcast/mcast +0/+0, p06 +110/+4; wan@eth0 p05 +129/+27, p06 +129/+28
(the same floods on both links); back on eth1 p05 +0/+0.

### Release stress test (2026-11-12, ipq50xx-2026.11.11, slot 0, AP profile)

Load from this host: 5 GHz ch36 HE80 client (`wlp2s0`, link 1200/1200) -> RA81 -> wan
-> iperf3 server in netns `ra81s` (10.0.0.51); wired UDP flood (`enp0s20f0u6` ->
10.0.0.3, 982 Mbit/s); a 24 MB mlocked RAM tester on the router (`memt`, five
patterns incl. all-ones and `0xffffff80...` pointers); kernel log over SSH; a reboot
watchdog that stops the client (bridged-AP TCP sessions survive a router reboot and
would keep loading it).

**Passed** (before the crash hunt): TCP/UDP up/down, ECM table fill and churn, 20x
`wifi reload`, network restarts, port flaps, 5 reboots (dual-boot flags confirmed each
time), a 2 h soak with LuCI polling (MemAvailable 38-50 MB, no leak),
`tools/validate-images.sh`, `tools/test-dualboot.sh`.

**Release blocker, fixed: the 1296 MHz CPU boost corrupts memory.** Under sustained
load the router oopsed or reset silently every few minutes (Wi-Fi downlink 4x100
Mbit/s: about every 4 min, 6 reboots in 26 min). Each of the five oopses faulted on a
kernel pointer with only bit 42 cleared (`ffffff80...` -> `fffffb80...`, once the
kernel image `ffffffc0...` -> `fffffbc0...`), in unrelated code (`tcp_poll`,
`anon_vma_interval_tree_remove`, ...). NSS Wi-Fi offload on or off made no difference.
`memt` found 7 single-bit 1->0 errors in 15 min of wired flood (six bit 42, one bit
1), **all at offset 8 of a 64-byte cache line**, and 0 in 2034 passes idle. A fixed bit
at a fixed position in the line is a hardware data-path fault, not a stale pointer.
The cause is fork patch 0974 (since 2026.11.07): 1296 MHz "above the rated 1008 MHz"
at the same 1.1 V (no CPU regulator), used by schedutil under load. TSENS was off in
this image, so nothing throttled it either (it is not thermal anyway: see the pinned
run below and the TSENS readings, 62-68 C, in the next section). The vendor firmware's table is 800/1008
MHz at 1.1 V. Runtime A/B on the same image:

| Run | CPU | Load | Result |
|---|---|---|---|
| n2 | schedutil 1008/1296 | dl 4x100M, host Wi-Fi | reset after 185 s (and every ~4 min) |
| w3 | schedutil | wired UDP flood 982M, 15 min | no reset, memt 7 errors |
| f1 | max 1008 | dl 4x100M, host Wi-Fi, 20 min | 400 Mbit/s, no reset, memt 0 / 723 passes |
| f2 | pinned 1296 (no rate changes) | dl 4x100M | silent reset 1.5 s into the load |
| f3 | max 1008 | dl 4 streams full rate, NSS offload, 30 min | 811 Mbit/s avg (727-913), memt 0 / 2980, MemAvailable 55 MB |
| f4 | max 1008 | bidir 4+4, NSS offload, 15 min | 751 down / 49 up, no reset, memt 0 / 1501, MemAvailable 54 MB |
| w4, w5 | max 1008 | wired UDP flood 982M, 2 x 15 min | no reset; memt 0 / 279 (w5; fewer passes, the flood takes the CPU). SSH to the router stalls during this flood at 1008 MHz |

f2 rules out the PLL relock/GPLL0 detour of 0973/0975: the clock was not changing.
NSS forwards the traffic, so the cap costs no throughput. Patch 0007 deletes the 1296
MHz operating point from the RA81 DTS (one OPP, 1008 MHz, as in the October
release). The fork's `xiaomi,redmi-ax3000-ubootmod` is the same IPQ5000 board; reported
as [kuncy7/openwrt-nss-edma#78](https://github.com/kuncy7/openwrt-nss-edma/issues/78)
(2026-11-12).

**Smaller findings:**
- **Downlink saturates the NSS Wi-Fi TX descriptor pool** (`tx_desc_alloc_fail`
  +3.2 M in 60 s at 748 Mbit/s, 4704 TCP retransmits): a parallel ping from the
  client to the gateway takes p50 64-73 ms, p95 91-122 ms under full load (f3, f4;
  1-2 ms idle, p50 8 ms at 400 Mbit/s). In bidir the downlink starves the upload:
  751 down / 49 up in f4 (upload alone 625). The upload's TCP ACKs wait behind the
  downlink queue. Bufferbloat rather than a fault: the offloaded path bypasses
  mac80211's fq_codel/AQL, and SQM cannot hook it.
- **`root` has no password** on the router (`Auth succeeded with blank password`).
  Not a sysupgrade bug: `/etc/shadow` is in the backup (`sysupgrade -b`), and the
  carried-over root entry is pristine (empty last-change field, which `passwd`/LuCI
  always fill in), so the password was never saved on the old system. Images ship
  without one (OpenWrt default); set one with `passwd`.
- **NSS Wi-Fi offload vs host Wi-Fi at 1008 MHz** (`nss.general.wifi_offload`, same
  client, 4 TCP streams, ping to the gateway alongside):

  | Mode | down | up | bidir down / up | ping avg dl / ul / bidir | router CPU idle |
  |---|---|---|---|---|---|
  | host (`0`) | 495 | 422 | 289 / 194 | 22 / 17 / 110 ms (bidir max 331) | 0-1 % |
  | offload (`1`, default) | 825 | 662 | 608 / 195 | 59 / 29 / 63 ms | 96-97 % |

  Offload stays the default: higher throughput in every direction and an idle CPU.
  Host mode has lower latency with one-way traffic but worse latency in bidir, because
  the CPU is saturated.
- ECM `disable_gro_list` (patch 0006) works: `rx-gro-list` is off on every physical
  port after boot; only `br-lan` keeps the flag, where it does nothing.

### Temperature sensor (TSENS, 2026-11-12, patch 0008)

The RA81 DTS had `&tsens { status = "disabled"; }`, because the boot firmware leaves the
block off ("tsens device is not enabled" with the vendor 5.4 kernel) and some zones were
said to report bogus critical temperatures. Checked on the router, slot 0, 1008 MHz:

- The upstream driver does not need the boot firmware: on the IPQ5018 it enables the
  block itself (`init_tsens_v1_no_rpm`: SW reset, sensor mask, enable).
- Calibration fuses (QFPROM 0x249-0x254, read through `qfprom0/nvmem`): **mode 3, two-point
  calibration** (30 and 120 C), base1 86, base2 160. Per sensor (code at 30 C / at
  120 C / slope): s0 468/692/2.49, s1 ubi32 416/696/3.11, s2 cpu 344/640/3.29, s3
  top-glue 396/680/3.15, s4 gephy 364/648/3.15 codes per C. All plausible (driver
  default slope 3.2).
- A test module (`tsensprobe.ko`, scratch, not in the image) mapped SROT 0x4a8000 / TM
  0x4a9000: HW version 0x10040000, `ctrl=0` (off). With the driver's enable sequence
  (`ctrl=0xf9`), all five sensors went valid:

  | State | s0 | ubi32 | cpu | top-glue | gephy |
  |---|---|---|---|---|---|
  | idle (6 h up, closed case) | 47.3 | 62.8 | 63.2 | 62.3 | 63.3 |
  | both cores at 100 % (`yes`), 15 s | 50.5 | 65.4 | 66.8 | 64.9 | 66.8 |
  | same, 4 min | 52.5 | 66.6 | 68.3 | 66.5 | 68.4 |
  | 2 min after | 47.3 | 63.1 | 63.8 | 63.3 | 64.2 |

  The four sensors used by the thermal zones agree within about 1 C and track the load;
  s0 (no zone in `ipq5018.dtsi`) reads 15 C lower. No bogus values.
- Patch 0008 sets `status = "okay"`: zones `cpu-thermal` (passive 100 C with cpufreq
  cooling, critical 120 C), `ubi32`, `top-glue` and `gephy` (critical 120 C). That is
  >50 C above what the board reaches here. The fork's own `redmi-ax3000-ubootmod` DTS
  never disabled it.
- **Side finding, upstream DT bug:** reading the whole `qfprom0` nvmem file (it is
  world-readable, 4 KiB) takes a synchronous external abort at offset 0x40c
  (`qfprom_reg_read`): the `ipq5018.dtsi` qfprom node maps 0x1000 bytes, but part of it
  is protected. With the default `panic_on_oops=1` any user can reboot the router with
  `cat /sys/bus/nvmem/devices/qfprom0/nvmem`. Offsets below 0x40c (which include the
  TSENS cells) read fine. The kernel survived because the stress test had set
  `panic_on_oops=0`, but it was left tainted.

### Temperatures under load and CPU clocks above 1008 MHz (2026-11-12, r0+38535, slot 1)

Same load for every run: 4-stream 5 GHz TCP downlink (`iperf3 -P4 -R`) to one client
through NSS Wi-Fi offload, plus the 24 MB mlocked RAM tester (`memt`), a reboot
watchdog, and a temperature log every 30 s (closed case, room temperature).

**1008 MHz soak with the release image (no manual cap; 1008 is its only OPP), 30 min:**
no reset, 741 Mbit/s average, RAM tester 0 errors (1200 passes; its SSH session dropped
after ~12 min because of Wi-Fi bufferbloat, before the DSCP EF rule was in place).
Zones: 63 C idle -> 71 C at 5 min -> 75 C -> **77 C plateau**.

**Higher clocks, set at runtime.** Above 1008 MHz there is no OPP in the image, so a
scratch module (`cpuclk.ko`, not in the image) called `clk_set_rate` on the CPU clock
directly. The `a53pll` steps in 24 MHz (L value), so 1104 = L46 is the closest to 1100.
cpufreq still reports 1008 (`scaling_cur_freq`). A dependent-add loop measured the real
clock each time. The runs went back to back, so each one started on a warm board.

| Clock (PLL) | Measured | Duration | Result | Throughput | RAM tester | Zones start -> peak |
|---|---|---|---|---|---|---|
| 1008 MHz | 973-983 | 30 min | ok | 741 Mbit/s | 0 errors | 63 -> 77 C |
| 1104 MHz | 1073-1078 | 15 min | ok, no kernel faults | 743 Mbit/s | 0 errors / 1658 passes | 72 -> 81 C |
| 1200 MHz | 1140-1172 | 15 min | ok, no kernel faults | 728 Mbit/s | 0 errors / 1778 passes | 76 -> 83 C |
| 1224 MHz | 1173-1196 | 15 min | ok, no kernel faults | 741 Mbit/s | 0 errors / 1805 passes | 64 -> 79 C |
| 1248 MHz | 1195-1220 | 15 min | ok, no kernel faults (fresh boot) | 755 Mbit/s | 0 errors / 1828 passes | 74 -> 83 C |
| 1272 MHz | 1227-1242 | 6 min, stopped | **RAM error at ~6 min** (pass 703): bit 42 cleared at offset 8 of a cache line, same signature as 1296 | 746 Mbit/s | **1 error** / 810 passes | 74 -> 80 C |
| 1296 MHz | 1262-1264 | - | **silent reset ~4 s into the load** (no oops logged, `panic_on_oops=0`) | - | - | 78 C at reset |

- The 1296 MHz result reproduces the earlier pinned run (reset 1.5 s into the load), this
  time with the clock set directly rather than through cpufreq-dt. The board was at
  78 C, below the 83 C it held for 15 min at 1200 MHz, so the failure is the clock, not
  the temperature.
- 1224-1272 ran later, after the 1296 reset. The RAM tester and the temperature logger ran
  on the router itself (detached), because in a first 1272 run the client's SSH sessions,
  and the tester with them, dropped 6 s into the load (Wi-Fi congestion, no router fault):
  that run stayed up 15 min but had no RAM coverage and is not counted. The 1272 error
  took the same ~6 min to appear as the first error in the release-default 1008/1296
  wired-flood run (05:56, 5.8 min in): a short test can miss it.
- This chip's limit at the fixed 1.1 V is **between 1248 and 1272 MHz**: 1248 passed
  15 min, 1272 corrupted memory within 6 min. That is one
  unit, and chips differ in margin at a fixed voltage, so passing at 1200 on this board
  says little about other RA81s. There is also nothing to gain: with offload the CPU is
  96-97 % idle at full Wi-Fi rate, and throughput did not change with the clock
  (743/728 vs 741 Mbit/s, client-bound). **The release stays at 1008 MHz** (patch 0007).
- Peak 83 C is far below the 100 C passive trip and the 120 C critical trip.

### Overclock variant (2026-11-12, patch 0009)

One build now produces two images: `xiaomi_redmi-ax3000` (1008 MHz only, unchanged) and
`xiaomi_redmi-ax3000-oc`, where the user picks the clock in LuCI, so there is no image
per clock.

- **DTS** `ipq5018-redmi-ax3000-oc.dts` includes the standard DTS and adds 1056, 1104,
  1152, 1200 and 1248 MHz (L 44-52 x 24 MHz, 1.1 V) as `turbo-mode` OPPs. cpufreq-dt
  (6.18) turns them into `CPUFREQ_BOOST_FREQ` entries: they appear in
  `scaling_boost_frequencies`, not `scaling_available_frequencies`, and stay unused while
  `/sys/devices/system/cpu/cpufreq/boost` is 0 (the default). Kernel boot, preinit and
  failsafe therefore run at 1008 MHz. Writing `boost=1` raises the policy limit to the
  highest boost point, so the limit has to be written after it. 1248 is the top step:
  1272 failed on this unit.
- **`luci-app-cpuclock`** (package/utils, in the OC image only, `=m` in the repository):
  `/etc/config/cpuclock` (`main.max_freq` in kHz, default 1008000, a conffile, kept by
  sysupgrade); `/etc/init.d/cpuclock` (START=90, procd reload trigger on `cpuclock`)
  for a boost point switches boost on, writes `scaling_max_freq` and then selects the
  `performance` governor; for 1008 it switches boost off and goes back to schedutil.
  A value that is not an OPP of the board falls back to 1008. The page is System -> CPU
  Clock: live clock/limit/boost/temperatures (5 s poll), a dropdown of the OPPs, an
  amber warning for any clock above 1008 and a red one above 1200 MHz (this unit's
  results).
- **schedutil cannot use the boost points** (found on the router 2026-11-12, first image
  of this variant, r0+38536): with boost 1 and `scaling_max_freq` 1248000, a full core
  of load (`memt`) plus Wi-Fi downlink kept the clock at 1008 MHz for 9 min
  (`stats/total_trans` 0); the `performance` governor went to 1248 at once. In 6.18,
  schedutil computes the next frequency from `arch_scale_freq_ref()`, which on arm64 is
  `capacity_freq_ref`: set from `cpuinfo.max_freq` when the policy is created
  (`init_cpu_capacity_callback`), i.e. 1008 MHz with boost off, and never updated. It also
  caps the utilisation at the CPU capacity (`sugov_effective_cpu_perf`), so it never asks
  for more than 1008 MHz. That image's overclock did nothing. Fix in the init script: an
  overclock is a fixed clock under `performance` (also what the clock tests above
  measured: pinned clocks). The order avoids passing through 1248: governor schedutil
  (stays at 1008) -> boost 1 -> `scaling_max_freq` -> performance; back down: boost 0
  (drops the clock to 1008 at once) -> max -> schedutil. On the router: 1104, 1248,
  1056, 1008, 1200, stop, start, `boost=0` (what `platform_pre_upgrade` writes: clock to
  1008) and restart each made exactly one transition to the expected clock. The rpcd ACL
  needed both `/sys/class/thermal/thermal_zone*/` and
  `/sys/devices/virtual/thermal/thermal_zone*/` patterns: `ubus file read` checks the path
  as given and its resolved target.
- **Shared:** same compatible `xiaomi,redmi-ax3000`, so board scripts, the dual-boot and
  sysupgrade are the same, and sysupgrade goes both ways (`SUPPORTED_DEVICES` lists only
  `xiaomi,redmi-ax3000` and `redmi,ax3000`). `platform_pre_upgrade` writes `boost=0`
  first, so the flash write runs at 1008 MHz (a no-op on the standard image: 6.18 creates
  the `boost` file there too, but it has no boost frequencies).
- **Build:** `configs/ra81.config` is now multi-profile with per-device rootfs. In that
  mode the subtarget's default packages that the device drops (kmod-usb3/dwc3,
  e2fsprogs, kmod-fs-ext4, losetup) are force-selected `=m`. They are built into the
  package repository but are not installed in either image. They change the kernel
  config (USB/ext4 modules), so the first build after the switch rebuilt the
  out-of-tree kmods (new vermagic).
- **Clocks through this path under load** (2026-11-12, the fixed init script on the
  router, OC image r0+38536): each run is Wi-Fi downlink 4 streams (~730 Mbit/s) plus
  `memt` (24 MB RAM tester) on one core, the clock set with `cpuclock` (performance
  governor); "switch" also toggles `scaling_max_freq` 1008 <-> the clock every 3 s so the
  PLL relocks under load.

  | Clock | Mode | Time | memt passes | Errors | Kernel faults | Max temp |
  |---|---|---|---|---|---|---|
  | 1248 | steady | 600 s | 1218 | 0 | 0 | 81 C |
  | 1248 | switch | 600 s | 1145 | 0 | 0 | 83 C |
  | 1200 | switch | 900 s (298 toggles) | 1679 | 0 | 0 | 85 C |
  | 1152 | switch | 600 s (199 toggles) | 1090 | 0 | 0 | 81 C |
  | 1056 | switch | 600 s (199 toggles) | 1029 | 0 | 0 | 82 C |

  The 1152/1056 runs were on the rebuilt OC image (r0+38536-8266bec00d, the governor fix
  in the package, not hand-copied). Wi-Fi downlink 728-745 Mbit/s in every run.
- **Release checks on the rebuilt images** (2026-11-12, `out/nss-2026.11.11-r0+38536-8266bec00d-cf8c2b597-files-ap`):
  sysupgrade old OC (slot 0) -> standard (slot 1) -> OC (slot 0) -> standard (slot 1),
  config kept, each boot confirmed by the dual-boot script, both radios up. The standard
  image soaked 30 min (Wi-Fi downlink 728 Mbit/s + `memt` 24 MB: 2998 passes, 0 errors,
  0 kernel faults, max 84 C). On the OC image a `uci set`/`commit` through rpcd (what the
  LuCI page does) switched to 1200 MHz performance at once, and after a reboot cpuclock
  restored 1200 MHz with one transition. The last sysupgrade started from 1200 MHz
  (boost 1, performance). The `cpuclock` section stays in the kept config on the standard
  image (no package reads it) and comes back if the OC image is installed again.
- `tools/validate-images.sh` checks both devices: OPP list (`1008` vs `1008 1056 1104
  1152 1200 1248`, 5 x `turbo-mode`), the cpuclock files and `S90cpuclock` only in
  the OC rootfs, the boost-off line in `platform.sh`, and sysupgrade metadata without an
  `-oc` compatible.

## To do next (written 2026-10-17)

1. ~~**Router-role test: WAN<->LAN NAT.**~~ done, wired client 922-930 Mbit/s (see "Router role" above; PPPoE still open). Original note: The last big unmeasured item for public users
   (target ~900 Mbit/s, the single-CPU-port ceiling). Build the generic image (no
   `--files`), install it into the inactive slot as a trial (overlay with a
   non-confirming `/etc/init.d/xiaomi-dualboot`, as for the first NSS boot - it
   changes the router's IP to 192.168.1.1 and turns on a DHCP server, so it must not
   sit on the home LAN). Bench: a WAN-side host (this host's onboard `eno1`, unused,
   into the RA81 WAN port, in a netns as "internet" with an iperf3 server) and a
   LAN-side client on a LAN port or Wi-Fi. Check ECM `tcp_accelerated_count`,
   `ipv4_rx_pkts` and CPU idle; also PPPoE if possible. Needs sudo (netns) and the
   owner to move cables.
2. ~~**Longer soak (a few hours)**~~ done, see "3 h soak" above (plateau, no leak). Original note: SUnreclaim rose 43.8 -> 47.0 MB in
   the last 5 min of the 30 min soak. Log MemAvailable/SUnreclaim/`drv_nss_skb_count`
   every minute; a steady climb = leak, a plateau = NSS pools filling.
3. **Sysupgrade with little free memory** (done 2026-10-17: hook in patch 0004,
   tested on the device, also through a full sysupgrade). The image (15 MB) goes to /tmp (RAM). With the 8 MB floor
   ~36 MB stayed available after copying it, but on a busy router it may not.
   Where sysupgrade can be hooked: nothing runs before the image reaches /tmp (LuCI
   upload, `scp`, `sysupgrade <url>` wget, or the `cp` of a non-/tmp path), and
   stage 1 (validate, config backup) allocates little. The only device hook is
   `platform_pre_upgrade`, in stage 2 after services are killed and caches dropped,
   before the ramfs copy and the flash write. At that point ath11k still holds its DP
   rings and `min_free_kbytes` 8192 is still reserved. Patch 0004
   (`xiaomi_redmi_ax3000_pre_upgrade`) lowers `min_free_kbytes` to 2048 (stock's
   `kill_plugin_process.sh` uses 512), unloads `ath11k_ahb`/`ath11k` in the
   background (waits at most 10 s, so a Q6 that will not stop cannot block the
   upgrade), drops caches and logs MemAvailable before and after (UART console only: stage 2's
   `kill_remaining` has killed logd by then, so `logger` goes nowhere). Nothing has
   been flashed yet at that point, so a hang or a crash leaves the running slot as it
   is.
   For the copy itself (stage 1, not hookable) document a manual step for tight
   cases: `wifi down; sync; echo 3 > /proc/sys/vm/drop_caches` before uploading.
   **Function test on the router (2026-10-17, slot 0, r0+37564 with the patch-0004
   `platform.sh` sourced from /tmp, AP up, 45 min uptime):** MemAvailable 50.3 MB
   idle, 49.7 MB after `wifi down`, **108.3 MB after the hook** (MemFree 106 MB,
   SUnreclaim 34.5 -> 29.3 MB); the hook took 2 s, `rmmod ath11k_ahb` returned with
   the NSS Wi-Fi offload loaded (`remoteproc0: stopped remote processor q6wcss`), no
   errors in dmesg, both log lines in `logread`. Rebooted: slot 0, 8192 again, AP up.
   **Full sysupgrade (2026-10-17, slot 0 -> slot 1):** AP image r0+37565-3701f3e36f
   (with 0004, sha256 `c62d5fdc...afe52`), Wi-Fi up during the copy, MemAvailable
   53.4 MB before and 30.6 MB after `scp` of the 15.4 MB image, `sysupgrade -v`
   (config kept). Back on SSH ~2 min later: slot 1 (`ubi.mtd=rootfs_1`),
   self-confirmed (`flag_last_success=1`, `flag_ota_reboot=0`, `flag_boot_success=1`),
   min_free 8192, ath11k loaded, test AP up, config (10.0.0.3, country BR) and SSH
   host key kept, MemAvailable 54.8 MB, 0 allocation failures/OOM/driver errors in
   dmesg. The hook's own log lines were not visible (no UART). The generic trial image
   that was in slot 1 is gone (see #5 (b)).
4. **Kernel module repository** (done locally 2026-10-18; CI publishing written, not
   yet run). Before: the image listed the snapshot target and `nss` feeds (the `nss`
   one fails, "unexpected end of file") and no kmods feed; `apk add kmod-wireguard` ->
   "no such package", and snapshot kmods would not load on our kernel anyway.
   - `configs/ra81.config`: 16 extra packages as `=m` (in the repository, not the
     image): wireguard, tun, gre, vxlan, l2tp, bonding, nft-queue/socket/tproxy,
     inet-diag, netlink-diag, sched-cake, fs-nfs, fs-cifs, nls-utf8 and
     `luci-app-nss` (kuncy7's `kmods-extra.config` without USB/local-disk modules,
     plus NFS/CIFS and cake). kmod-gre/l2tp also build the GRE/L2TPv2 handlers into
     `qca-nss-drv`, as in the fork's releases.
   - `configs/distfeeds.list` -> the image's `/etc/apk/repositories.d/distfeeds.list`
     (`scripts/build.sh`): `@REPO@` (= `build.sh --repo URL`, dropped without it),
     then the official snapshot base/luci/packages/routing/telephony/video feeds.
   - `build.sh` copies the target repository (plus the `=m` non-kmod packages,
     re-indexed, signed with the build key) to `out/<dir>/packages/` (117 packages,
     3.9 MB), drops kmods the config no longer selects (`bin/` is never cleaned), and
     names `out/` dirs `<label>-<rev>-c<config id>` so a config change no longer
     overwrites an earlier build.
   - CI (`.github/workflows/build.yml`): tag `ra81-<label>-run<N>` fixed before the
     build; with `release`, the image gets `--repo
     https://<owner>.github.io/<repo>/<tag>`; job `pages` pushes `packages/` to
     gh-pages `<tag>/` (one orphan commit, newest 10 kept, `index.md`); the release
     waits for it. Needs GitHub Pages enabled on the gh-pages branch (repository
     settings) once the branch exists. The first three CI runs failed in
     tools/libtool ("autoconf (GNU Autoconf) false"): gnulib's `maint.mk`, which
     autoconf's GNUmakefile includes, turns an environment `RELEASE` into the staged
     autoconf's `VERSION`. The workflow now passes `PUBLISH`, and `build.sh` unsets
     `RELEASE` (2026-11-12). The fourth run built and validated both image sets, then
     failed on `ccache --show-stats`: ccache had never been on, locally or in CI,
     because `CONFIG_CCACHE` has a prompt only `if DEVEL` and defconfig dropped it.
     `build.sh` now adds `CONFIG_DEVEL=y` (it only makes developer options visible;
     the resolved config differs in nothing else that is built). Run 43343730923
     (2026-11-13, no release, 60 min) passed: both image sets validated, dual-boot
     scenarios pass, 232 MiB ccache saved for the next run. Its repository, served over
     HTTP to the router and checked with only the key from the CI image
     (`--keys-dir`), updates (238 packages) and lists `kmod-wireguard`/`luci-app-nss`;
     with the router's own build key it is rejected (untrusted signature), as it
     should be. Also fixed: the `build/openwrt` paths in the
     workflow, `validate-images.sh` and `test-dualboot.sh` (they now read `SRC` from
     `patches/BASE`).
   - **Boot crash on the way (2026-10-17/18):** the first image with the `=m` list
     died ~20-30 s into boot (after preinit's arm, before networking) - 3 trials, each
     rolled back by U-Boot (`flag_boot_success=0` left behind, seen with slot 1's
     confirm disabled). A control sysupgrade of the old image into the same slot
     booted, so not the upgrade path. Cause: `kmod-vxlan`/`kmod-wireguard` enable
     `CONFIG_NET_UDP_TUNNEL`, which adds a field to `struct netns_ipv4` and shifts
     `struct net`; OpenWrt rebuilt the in-tree modules but not the out-of-tree kmod
     packages (mac80211 backports, NSS clients/ECM, dsa/dwmac, switch drivers, built
     on 10-16), so `ecm.ko` ran with the old layout. Fix in `build.sh`:
     `.ra81-vermagic` records the kernel they were built against; on a change it
     runs `make <dir>/clean` for every selected out-of-tree kmod package and builds
     again (tested in `tools/test-build.sh`). CI builds from scratch and never hit it.
   - **On the router (2026-10-18, slot 1, `out/...-c8c05dd31-files-ap`, sha256
     `b465e42e...`):** sysupgrade from slot 0, self-confirmed, NSS core booted, "NSS
     wired plane + ECM up", test AP up, MemAvailable 53 MB, no oops/allocation
     failures. Repository copied to the router's /tmp: `apk add --repository
     /tmp/repo/packages.adb kmod-wireguard` installed it and 7 dependencies (signature
     trusted, no `--allow-untrusted`), `modprobe wireguard` loaded, `ip link add
     wgtest type wireguard` worked; `luci-app-nss` resolves. Removed again afterwards.
     Not tested: fetching over HTTP from gh-pages (no publish yet).

5. **PPPoE test (do later; estimate 1.5-2 h hands-on, +1 h with a soak).** Nothing has
   been run with PPPoE on the RA81. Why it may fail (from kuncy7's history, all fixes
   are in our base `dff118f852`, none verified here):
   - The NSS PPPoE manager (`qca_nss_pppoe`) only learns sessions created after it
     loads; if the session is older, ECM finds no interface for `pppoe-wan`, every flow
     stays on the host (48 % CPU in the fork's measurement) and **nothing is logged**
     (`7247752c6a`, `50e99a8cd8`). `nss-dwmac-up` re-dials every PPPoE interface after
     the arm and logs "PPPoE: wan re-created" (`b2b6b3fff8`): check that on a cold boot.
   - ECM deadlock against the ppp xmit path; fixed by the lockless helpers of kernel
     patch 0961 (`0403ddf10a`). Only shows under load -> soak.
   - Tagged PPPoE (`wan.35`, common ISP setup) goes through the qca-8021q tagger and the
     firmware VLAN interface for the 802.1Q upper (`9ae6490255`, `ecb1d2daed`): recent
     code, tested by the fork on the MX2000 (same QCA8337/SGMII topology) only.
   - SQM with PPPoE has limits (fork README); not a throughput issue.

   Plan: (a) on the host check for `pppoe-server` or `pppd` with the pppoe plugin
   (install needs root); run it in the `inet` netns on `eno1` (extend
   `tools/bench-nat.sh`, e.g. a `--pppoe` mode: server 172.16.0.1 <-> client
   172.16.0.2 with chap, MTU 1492; also a VLAN-35 variant). (b) Reinstall the generic
   trial image into the inactive slot with `ra81-install-slot.sh`, as in the NAT test
   below (`out/nss-2026.10.15-2-r0+37564-e8dda8ca92-files-trial/`, sha256
   `158576af...5011`, or a rebuild with 0004): the sysupgrade test of #3 overwrote
   it on 2026-10-17. (c) Router: `wan` proto pppoe (username/password of the test
   server), cold boot, then check `logread | grep -i pppoe`, `dmesg`, ECM
   `tcp_accelerated_count` rising, `/sys/kernel/debug/qca-nss-drv/stats/pppoe`
   non-zero, CPU idle. (d) Wired matrix with `sudo tools/bench-wired.sh` (expect
   ~900+ Mbit/s, CPUs idle), plain and tagged. (e) Optional 1 h soak with
   `tools/soak-mem.sh --load`. (f) Revert: uplink back in the WAN jack, power-cycle
   (the trial never confirms, U-Boot falls back to slot 0), `sudo sh
   tools/bench-nat.sh down`, `sudo nmcli con up APT22`.

   Session notes for the next run: this host's NetBird session rides
   `enp0s20f0u6` - do not move that cable. `nmcli`/`ip netns` need `sudo` (polkit
   refuses NetBird SSH sessions), so give the user `!` commands. The bench NICs:
   `eno1` (-> WAN jack, "internet" netns `inet`), RTL8153 USB GbE
   `enp0s20f0u2u1` (-> `lan1`, wired client netns `lanc`, enabled by
   `bench-wired.sh`), `wlp2s0` (Wi-Fi client on the test AP; needs the key in
   `RA81-iperf`, `sudo nmcli -s -g 802-11-wireless-security.psk con show RA81-iperf`).
   Reach the trial router at 192.168.1.1 (via `eno1` on a LAN jack, or `wlp2s0`);
   the dead-wired-route trap: with `enp0s20f0u6` unplugged the host's SSH to 10.0.0.x
   fails until the `10.0.0.0/23` route on it is removed.

Smaller, when convenient: 2.4 GHz AP test on the NSS path; press-test reset/mesh
buttons; optionally `min_free_kbytes` 4096; the second CPU link (GMAC0 -> port 5 for
WAN, plan step 3); README for the NSS line.

## State left on the router (10.0.0.3) on 2026-11-12

- **Slot 1** (running, confirmed: `flag_last_success=1`, `flag_boot_success=1`): the
  release candidate, standard image (1008 MHz, schedutil, no boost frequencies),
  `out/nss-2026.11.11-r0+38536-8266bec00d-cf8c2b597-files-ap`, AP profile, installed by
  sysupgrade from the OC image at 1200 MHz with config kept. **Slot 0** (fallback): the
  OC image of the same build. Older images (r0+38535 standard, r0+38533 with the 1296
  MHz OPP, the first OC image without the governor fix) are gone from the flash.
- Kept config: `/etc/config/cpuclock` with `max_freq` 1200000 (unused on the standard
  image; the OC image would apply it). Four thermal zones at 73-75 C idle,
  `panic_on_oops=1`, `nss.general.wifi_offload=1`, only the `inet fw4` nft table, no test
  tools in `/tmp` (all runtime test state went with the sysupgrade).
- Wi-Fi: the owner's AP config, 5 GHz ch36 HE80, 2.4 GHz ch1. The uplink is in the WAN
  jack (bridged, `wan` on `eth1` per the AP profile).
- **Root has no password**: set one with `passwd`.
- Host side: the bench namespace from `tools/bench-netns.sh up` is still up (wlp2s0
  pinned to the RA81 5 GHz BSSID); `sudo sh tools/bench-netns.sh down` removes it.

## State left on the router (10.0.0.3) on 2026-10-18

- **Slot 1** (running, confirmed, since 2026-10-18 01:59): NSS AP image with patches
  0001-0004 and the `=m` package list (kernel `~9a0ce504...`, feed list from
  `configs/distfeeds.list`), `out/nss-2026.10.15-2-r0+37565-3701f3e36f-c8c05dd31-files-ap`.
  **Slot 0** (fallback): generic image r0+37564-e8dda8ca92 (no 0004) with the kept AP
  config. The generic trial image is no longer on the flash. The 25.12 images are no longer on the flash (restore from
  `out/v25.12.5-*` with `ra81-install-slot.sh`, or `ra81-backup/`).
- Test AP `RA81-iperf` on radio1 (5 GHz ch36 HE80, country BR), psk2+ccmp with a random
  key generated on 2026-10-17 (in the host's NetworkManager profile `RA81-iperf`;
  `sudo nmcli -s -g 802-11-wireless-security.psk con show RA81-iperf`). Disable with
  `uci set wireless.default_radio1.disabled=1; uci commit wireless; wifi`.
- The uplink is in the WAN jack (bridged into br-lan by the AP profile).
- This host: netns `ra81s` (macvlan on `enp0s20f0u6`, 10.0.0.51, iperf3 server),
  `arp_ignore=1` on `enp0s20f0u6`, `wlp2s0` on `RA81-iperf`. Undo:
  `sudo sh tools/bench-netns.sh down`. Runs: `tools/bench-run.sh "<label>" [iperf3
  args]` (e.g. `-R -P 4`).
