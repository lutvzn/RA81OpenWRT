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
4. **Kernel module repository.** The image lists the OpenWrt snapshot feeds; their
   kmods are for another kernel (vermagic `93ef0a8c...` vs ours `c700d69b...`) and the
   `nss` feed URL 404s. Publish our build's kmods (`bin/targets/.../packages`) with each
   release, e.g. GitHub Pages as kuncy7 does, and point the image's repositories at
   it (`CONFIG_VERSION_REPO` / feed list).

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

## State left on the router (10.0.0.3) on 2026-10-17

- **Slot 1** (running, confirmed, since the sysupgrade test of 2026-10-17 23:17):
  NSS AP image with patches 0001-0004 (ath11k NSS 256M profile, min_free 8192,
  pre-upgrade hook), r0+37565-3701f3e36f. **Slot 0** (fallback): the same without
  0004, r0+37564-e8dda8ca92. The generic trial image is no longer on the flash. The 25.12 images are no longer on the flash (restore from
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
