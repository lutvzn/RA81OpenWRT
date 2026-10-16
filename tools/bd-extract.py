#!/usr/bin/env python3
"""Extract each board data blob from a board-2.bin into OUTDIR/<sanitized-name>.bin"""
import os, re, struct, sys
path, outdir = sys.argv[1], sys.argv[2]
os.makedirs(outdir, exist_ok=True)
d = open(path, 'rb').read()
off = (d.index(b'\0') + 1 + 3) & ~3
while off + 8 <= len(d):
    ie_id, ie_len = struct.unpack_from('<II', d, off); off += 8
    body = d[off:off+ie_len]; off += (ie_len + 3) & ~3
    names, data, sub = [], b'', 0
    while sub + 8 <= len(body):
        sid, slen = struct.unpack_from('<II', body, sub); sub += 8
        sdata = body[sub:sub+slen]; sub += (slen + 3) & ~3
        if sid == 0: names.append(sdata.decode())
        else: data = sdata
    for n in names:
        fn = os.path.join(outdir, re.sub(r'[^A-Za-z0-9.-]+', '_', n.replace('=', '-')) + '.bin')
        open(fn, 'wb').write(data); print(fn)
