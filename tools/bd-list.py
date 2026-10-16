#!/usr/bin/env python3
"""List board names (and data sizes/md5) inside an ath10k/ath11k board-2.bin."""
import hashlib, struct, sys
for path in sys.argv[1:]:
    d = open(path, 'rb').read()
    magic_end = d.index(b'\0') + 1
    off = (magic_end + 3) & ~3
    print(f"== {path}: magic={d[:magic_end-1].decode()} size={len(d)}")
    while off + 8 <= len(d):
        ie_id, ie_len = struct.unpack_from('<II', d, off); off += 8
        body = d[off:off+ie_len]; off += (ie_len + 3) & ~3
        if ie_id not in (0, 1):
            print(f"  ie {ie_id} len {ie_len}"); continue
        names, sub = [], 0
        while sub + 8 <= len(body):
            sid, slen = struct.unpack_from('<II', body, sub); sub += 8
            sdata = body[sub:sub+slen]; sub += (slen + 3) & ~3
            if sid == 0: names.append(sdata.decode(errors='replace'))
            else: data = sdata
        for n in names:
            print(f"  {n}  [{len(data)} bytes md5 {hashlib.md5(data).hexdigest()[:12]}]")
