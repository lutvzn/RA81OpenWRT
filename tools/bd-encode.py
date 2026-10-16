#!/usr/bin/env python3
"""Build an ath11k board-2.bin from raw board data files.

Usage: bd-encode.py OUT.bin "NAME=FILE" ["NAME=FILE" ...]

Equivalent to qca-swiss-army-knife's ath11k-bdencoder for the simple case:
one ATH11K_BD_IE_BOARD element per entry, each holding a BOARD_NAME and a
BOARD_DATA sub-element, all 4-byte aligned.
"""
import struct
import sys

MAGIC = b"QCA-ATH11K-BOARD\0"
IE_BOARD = 0
IE_BOARD_NAME = 0
IE_BOARD_DATA = 1


def pad4(b: bytes) -> bytes:
    # Pad with "m" like ath11k-bdencoder does (content is ignored by ath11k).
    return b + b"m" * (-len(b) % 4)


def tlv(ie_id: int, payload: bytes) -> bytes:
    return struct.pack("<II", ie_id, len(payload)) + pad4(payload)


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    out = pad4(MAGIC)
    for spec in sys.argv[2:]:
        # Board names contain '=' themselves, so split on the last one.
        name, path = spec.rsplit("=", 1)
        data = open(path, "rb").read()
        body = tlv(IE_BOARD_NAME, name.encode()) + tlv(IE_BOARD_DATA, data)
        out += tlv(IE_BOARD, body)
    open(sys.argv[1], "wb").write(out)


if __name__ == "__main__":
    main()
