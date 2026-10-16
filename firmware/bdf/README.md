# Wi-Fi board data files (BDF)

These two files are installed by the `ipq-wifi-xiaomi_redmi-ax3000` package (they are
also embedded in `patches/0001-*.patch` under `package/firmware/ipq-wifi/src/`):

| File | Radio | Board name inside | Payload md5 |
|---|---|---|---|
| `board-xiaomi_redmi-ax3000.ipq5018` | IPQ5000 2.4 GHz | `bus=ahb,qmi-chip-id=0,qmi-board-id=255,variant=Xiaomi-Redmi-AX3000` | `4ff708b50823…` |
| `board-xiaomi_redmi-ax3000.qcn6122` | QCN6102 5 GHz | same | `744abea52f1f…` |

## Provenance

The payloads are Xiaomi/Qualcomm board data for the Redmi AX3000 (CR880x "M81"
hardware). They were taken unmodified from
[hzyitc/openwrt-redmi-ax3000](https://github.com/hzyitc/openwrt-redmi-ax3000), branch
`ipq50xx-qsdk-kernel-5.4-openwrt-21.02-qsdk-11.5.05.841.1029`, files
`package/firmware/ipq-wifi/board-redmi_ax3000.{ipq5018,qcn6122}`
(md5 `9acb0e52…` / `c34b1769…`):

- IPQ5000: the entry `qmi-board-id=36` (board ID 0x24)
- QCN6102: the entry `qmi-board-id=96` (board ID 0x60)

Only the board name was changed (repacked with `tools/bd-encode.py`, whose output is
byte-identical to qca-swiss-army-knife's `ath11k-bdencoder`):

```
tools/bd-extract.py board-redmi_ax3000.ipq5018 out/
tools/bd-encode.py board-xiaomi_redmi-ax3000.ipq5018 \
  "bus=ahb,qmi-chip-id=0,qmi-board-id=255,variant=Xiaomi-Redmi-AX3000=out/bus-ahb_qmi-chip-id-0_qmi-board-id-36.bin"
```

## Why these and not others

- Upstream ath11k firmware reports `qmi-board-id=255` on IPQ5018/QCN6122, so the
  original board-ID-keyed names never match; boards are selected by `variant=` instead.
- Board ID 0x24 (not 0x10) is what the RA81's factory calibration in `0:ART` records and
  what the stock U-Boot passes (`cnss2.bdf_integrated=0x24`) on every RA81.
- The BDFs shipped in the stock RA81 firmware 1.0.33 are an older template (for
  WLAN.HK.2.5) and make the WLAN.HK.2.7.0.1 firmware used by OpenWrt assert
  (`phyrf_bdf.c: Assertion axis_value == ANTENNACHAIN_AXIS_Z failed`) — tested.

## License

These are proprietary binary blobs, not covered by this repository's license. They are
redistributed for interoperability, in the same way OpenWrt's
[qca-wireless](https://git.openwrt.org/?p=project/firmware/qca-wireless.git) repository
distributes board files for other devices.
