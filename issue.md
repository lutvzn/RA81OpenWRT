# ipq50xx (qca8k, tag_8021q): bridging wan with lan1-3 across both CPU links floods every broadcast/multicast up both conduits

**Release:** `ipq50xx-2026.11.11` (branch `c3po-tag-8021q`, kernel 6.18.60, NSS fw 12.5-210).
Nothing on the branch after the tag (checked up to b0c52c9563, 2026-11-11) changes the
code involved.

**Affected:** every board whose board.d splits the ports across both CPU links
(`wan` on `eth0`, `lan1-3` on `eth1`): `xiaomi,cr8806`, `xiaomi,redmi-ax3000-ubootmod`,
`xiaomi,redmi-ax5400`, `cudy,p5`, `cmcc,pz-l8`. It shows as soon as `wan` is added to
`br-lan`, which is the usual dumb-AP / mesh-node setup ("WAN port as an extra LAN port").
The router role, where `wan` is not bridged, is not affected.

Measured on a Redmi AX3000 (RA81, IPQ5000 + QCA8337, GMAC1 -SGMII- port 6 for lan1-3,
GMAC0 -GE PHY- port 5 for wan; same switch and split as the CR880x). This is my own
out-of-tree port, but it changes no kernel or nss-tools code, only the DTS and board
files. The board name sits in the same board.d case as `xiaomi,cr8806`.

## Symptom

- Wi-Fi clients get every upstream broadcast and multicast frame twice, 3-5 ms apart.
  In a 60 s capture on a Wi-Fi client, all of the broadcast/multicast frames were
  doubled (ARP, mDNS, the gateway's UDP broadcasts; 302 of 606 frames were duplicates).
- With no LAN port up, the second copy is dropped by the tagger instead, and the log fills with:
  `eth1: dropped frame from <mac> proto 0x.... src_port=... switch_id=... vid=... vbid=1`
  (`net_warn_ratelimited` in `761-net-dsa-qca8k-add-802.1Q-VLAN-based-tag-driver.patch`).
- With a LAN port up, the copy is delivered as if it came from that LAN port. br-lan then
  intermittently learns upstream MACs (the gateway, other hosts) on that LAN port.
  Unicast still works: with tx_fwd_offload, the switch's FDB picks the egress port
  (900 pings from Wi-Fi to upstream hosts, 0 lost). Still, the bridge FDB is wrong and
  every flood is doubled.

## Cause

1. `dsa_tag_8021q_bridge_join()` adds the bridge VID (3088 + bridge num) for each joining
   port via `dsa_port_tag_8021q_vlan_add()`.
2. `dsa_port_tag_8021q_vlan_match()` (patch
   `784-net-dsa-tag_8021q-give-a-port-s-VLAN-only-to-its-own-CPU-port.patch`, 68c6b32bda)
   gives a CPU port the VID when the user port it is adding belongs to that CPU port.
   That is right for the standalone VIDs. For the bridge VID, the `wan` join adds port 5
   and the `lan1-3` joins add port 6, so VLAN 3088 contains **both** CPU ports.
3. The QCA8337 ports run in 802.1Q secure mode, where floods follow VLAN membership.
   The port lookup masks are correct (`wan`'s mask excludes port 6), but the VLAN table
   still sends the flood to both CPU ports.
4. 4d73bf55e2 ("nss-tools: keep the DSA conduit split that board.d made") keeps the
   split for configs carried over by sysupgrade too, so upgrading an existing AP to
   2026.11.11 is enough to hit this.

## Measurements

Switch MIB (`ethtool -S eth1`, `s00_p0[56]_Tx{Broad,Multi}`), 30 s per run, uplink on
`wan`, one host on `lan3`, `wan` in br-lan, the conduit changed at runtime:

| `wan` conduit | port 5 (eth0) Tx bcast / mcast | port 6 (eth1) Tx bcast / mcast |
|---|---|---|
| eth1 (all ports on one link) | +0 / +0 | +110 / +4 |
| **eth0 (board.d split)** | **+129 / +27** | **+129 / +28** |
| eth1 again | +0 / +0 | +133 / +13 |

With the split, both links carry the same floods frame for frame.

On one conduit, nothing is lost for an AP: wan<->lan is switched in hardware, and the
Wi-Fi traffic leaves through `wan` either way. 5 GHz HE80 client, 4 streams:
split dl 775 / ul 806 Mbit/s, single conduit dl 826 / ul 767 Mbit/s, both at 94-97 % CPU idle.

## Reproduce

1. A split board on 2026.11.11, uplink cable in the WAN port.
2. `uci add_list network.@device[0].ports='wan'; uci commit network; reload_config`
   (br-lan is `@device[0]` on a fresh config).
3. Read the counters twice, 30 s apart: `ethtool -S eth1 | grep -E 's00_p0[56]_Tx(Broad|Multi)'`
   (the CPU-port MIB is appended to either conduit). Both CPU ports rise at the same rate.
4. Optional: `tcpdump -e -n 'broadcast or multicast'` on a Wi-Fi client shows the pairs.

## Workaround

Put `wan` on the LAN conduit (the override the nss-tools log message already describes):

```
uci add network device
uci set network.@device[-1].name='wan'
uci set network.@device[-1].conduit='eth1'
uci commit network
reboot   # or: ip link set wan type dsa conduit eth1
```

Afterwards: `wan@eth1`, `fw_mask: 0x2`, port 5 sends nothing, no more dropped-frame warnings.

## Possible fixes

- **Userspace (smallest):** when a bridge contains DSA ports on different conduits, move
  those ports onto one conduit, e.g. in `nss-dwmac.defaults`, or in a hotplug/netifd hook
  that runs again when the bridge's ports change in LuCI. At least log a warning about it,
  like the existing "stray ports" message in `nss-dwmac.init`.
- **Kernel:** for a bridge VID, add only one CPU port to the VLAN (e.g. the
  first member's), and make the tagger and xmit agree on that CPU port. This is harder,
  because `wan`'s host traffic leaves through `eth0` with that VID.
- **Docs:** README.ipq50xx.md should say that the split is for the router role, and give
  the one-line override above for AP setups.
