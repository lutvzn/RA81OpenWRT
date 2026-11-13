# ipq50xx-2026.11.07+: the 1296 MHz CPU boost (0974) corrupts memory and resets an IPQ5000 under load

**Release:** `ipq50xx-2026.11.11` (branch `c3po-tag-8021q`, kernel 6.18.60, NSS fw 12.5-210,
256M profile); the boost is in every release since `ipq50xx-2026.11.07` (09217c4a61,
"keep the CPU at 1008 MHz or above", patches 0973-0975). Board: Redmi AX3000 (RA81,
**IPQ5000**, `CPU: IPQ5000, SoC Version: 1.1`, 256 MiB, QCA8337). This is my out-of-tree
port (DTS/board files only, no kernel or NSS code changes), and the fork's
`xiaomi,redmi-ax3000-ubootmod` is the same board.

DRAFT - not posted.

## Symptom

Under sustained network load (Wi-Fi downlink 400-760 Mbit/s, or a wired UDP flood into
the router) the board oopses or silently resets after seconds to ~40 minutes, about
every 4 minutes under a 400 Mbit/s downlink. Every oops faults on a kernel pointer with
**bit 42 cleared** and nothing else changed:

| Mode | Faulting address | Expected pointer | Where |
|---|---|---|---|
| NSS Wi-Fi offload, bidir | `fffffb800e9b1390` (write) | `ffffff800e9b1390` | linear map |
| offload, dl | `fffffb800474bc78` | `ffffff800474bc78` | `anon_vma_interval_tree_remove` (mmap from awk) |
| offload, dl 400 Mbit/s | `fffffbc080e180e8` | `ffffffc080e180e8` (kernel image, `sock->ops`) | `tcp_poll` (dropbear) |
| offload | `fffffb80090e7848` | `ffffff80090e7848` | linear map |
| host Wi-Fi (`wifi_offload=0`), dl | `fffffb800f78c6f0` | `ffffff800f78c6f0` | linear map, 185 s after boot |

A userspace RAM tester (24 MB, mlocked, five patterns) running on the router during a
15 min wired UDP flood (982 Mbit/s into the router, no Wi-Fi traffic) found 7 errors,
all single bits cleared (1 -> 0): six of bit 42, one of bit 1, and **all seven at
offset 8 of a 64-byte cache line**. The same tester found 0 errors in 2034 passes on an
idle router. A fixed bit at a fixed position in the cache line points at the hardware
data path, not at a software use-after-free.

## Cause: the 1296 MHz operating point

0974 adds 1296 MHz "above the rated 1008 MHz" at the same 1.1 V (the boards have no CPU
regulator), and schedutil uses it under load. On this IPQ5000 (runtime A/B, same image,
same load: 4 x 100 Mbit/s 5 GHz downlink to one client, plus the RAM tester):

| CPU clock | Result |
|---|---|
| schedutil 1008/1296 (release default) | resets/oopses every ~4 min, RAM tester errors |
| `scaling_max_freq=1008000` | 20 min, no reset, 0 errors in 723 passes |
| `scaling_min_freq=scaling_max_freq=1296000` (no rate changes) | silent reset 1.5 s into the load |
| capped at 1008, NSS Wi-Fi offload, 4 streams full rate (811 Mbit/s avg) | 30 min, no reset, 0 errors in 2980 passes |
| capped at 1008, offload, bidirectional (751 down / 49 up) | 15 min, no reset, 0 errors in 1501 passes |
| capped at 1008, wired UDP flood 982 Mbit/s into the router | 15 min, no reset, 0 errors in 279 passes |

Capping the clock costs nothing with NSS offload: the router CPU stays 96-97 % idle at
825 Mbit/s downlink.

The pinned run rules out the PLL relock and GPLL0 detour of 0973/0975: the clock was
not changing when the board reset. The October release (`ipq50xx-2026.10.15-2`, single
1008 MHz operating point) ran the same AP for a 3 h soak without a fault.

Notes:
- The vendor firmware on this board lists 800 and 1008 MHz at 1.1 V only
  (`operating-points = <800000 1100000 1008000 1100000>`).
- The IPQ5000 is a different SKU from the IPQ5018 in the GL-B3000 the boost was tested
  on, so a pass there says little about IPQ5000 boards (and individual chips differ
  in margin at a fixed voltage anyway).
- It is not thermal, so the safety net in the 0974 description (the 100 C cpu-thermal
  trip) would not catch it. With TSENS enabled (the fork's `redmi-ax3000-ubootmod` keeps
  it on; my DTS had it off during these runs), this board's zones read 62-63 C idle and
  68 C after 4 minutes of both cores at 100 % at 1008 MHz, and the pinned-1296 MHz run
  reset 1.5 s into the load. With TSENS on, under the same Wi-Fi load plus the RAM
  tester, the CPU clock was set directly with `clk_set_rate`. 1104, 1200, 1224 and
  1248 MHz each ran 15 min with no reset and 0 tester errors, peaking at 79-83 C.
  1272 MHz cleared bit 42 at offset 8 of a cache line after 6 min, at 80 C. 1296 MHz
  reset the board silently 4 s into the load, at 78 C. So this chip's limit at 1.1 V
  lies between 1248 and 1272 MHz, 2-4 % below the boost, which leaves no margin for
  chip-to-chip variation.

## Suggested fix

Keep 1296 MHz off by default, or at least on IPQ5000 boards (e.g. key it on the SoC ID or
a speed-bin fuse with `opp-supported-hw`, or only add it in the DTS of boards tested at
that clock). Per board it is:

```
&cpu_opp_table {
	/delete-node/ opp-1296000000;
};
```

Runtime workaround: `echo 1008000 > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq`
(e.g. from `/etc/rc.local`).

## Oops traces

```
Unable to handle kernel paging request at virtual address fffffbc080e180e8
[fffffbc080e180e8] address between user and kernel address ranges
Internal error: Oops: 0000000096000004 [#1]  SMP
CPU: 0 UID: 0 PID: 20206 Comm: dropbear Tainted: G           O        6.18.60 #0 NONE
Hardware name: Xiaomi Redmi AX3000 (DT)
pc : tcp_poll+0x2b8/0x2f4
lr : sock_poll+0x58/0xe4
Call trace:
 tcp_poll+0x2b8/0x2f4 (P)
 sock_poll+0x58/0xe4
 do_select+0x264/0x6a0
 core_sys_select+0x2b8/0x440
 __arm64_sys_pselect6+0x130/0x224
```

```
Unable to handle kernel paging request at virtual address fffffb800474bc78
Internal error: Oops: 0000000096000004 [#1]  SMP
CPU: 0 UID: 0 PID: 8235 Comm: awk Tainted: G           O        6.18.60 #0 NONE
pc : anon_vma_interval_tree_remove+0x19c/0x2e8
lr : vma_prepare+0x94/0x144
Call trace:
 anon_vma_interval_tree_remove+0x19c/0x2e8 (P)
 vma_prepare+0x94/0x144
 commit_merge+0x74/0x1e0
 vma_expand+0xcc/0x270
 vma_merge_new_range+0x80/0x17c
 __mmap_region+0x34c/0x900
```
