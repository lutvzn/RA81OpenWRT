#!/usr/bin/env python3
"""Disassemble (Thumb-2) the code around literal-pool references to a string
in an ARM32 U-Boot ELF, annotating PC-relative literal loads.

Usage: uboot-xref.py UBOOT.elf "substring" [before] [after]
"""
import struct
import sys

from capstone import CS_ARCH_ARM, CS_MODE_THUMB, Cs

d = open(sys.argv[1], 'rb').read()
needle = sys.argv[2].encode()
before = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0x200
after = int(sys.argv[4], 0) if len(sys.argv) > 4 else 0x40

phoff, = struct.unpack_from('<I', d, 0x1c)
phnum, = struct.unpack_from('<H', d, 0x2c)
segs = []
for i in range(phnum):
    p_type, off, vaddr, _, filesz, *_ = struct.unpack_from('<8I', d, phoff + i * 32)
    if p_type == 1:
        segs.append((vaddr, off, filesz))


def f2v(o):
    for v, off, sz in segs:
        if off <= o < off + sz:
            return v + o - off


def v2f(a):
    for v, off, sz in segs:
        if v <= a < v + sz:
            return off + a - v


def cstr(a):
    o = v2f(a)
    if o is None:
        return None
    e = d.find(b'\0', o, o + 120)
    s = d[o:e]
    if e > o and all(32 <= c < 127 or c in (9, 10) for c in s):
        return s.decode()
    return None


md = Cs(CS_ARCH_ARM, CS_MODE_THUMB)

# Start offsets of every NUL-terminated string containing the needle
starts = []
pos = d.find(needle)
while pos >= 0:
    st = d.rfind(b'\0', 0, pos) + 1
    if st not in starts:
        starts.append(st)
    pos = d.find(needle, pos + 1)

for so in starts:
    sva = f2v(so)
    if sva is None:
        continue
    print(f"string @ {sva:#x}: {cstr(sva)!r}")
    lit = struct.pack('<I', sva)
    lo = d.find(lit)
    while lo >= 0:
        print(f"  literal @ {f2v(lo):#x}")
        start = max(lo - before, 0) & ~1
        for ins in md.disasm(d[start:lo + after], f2v(start)):
            note = ''
            if ins.mnemonic.startswith('ldr') and '[pc, #' in ins.op_str:
                tgt = ((ins.address + 4) & ~3) + int(ins.op_str.split('#')[1].rstrip(']'), 0)
                fo = v2f(tgt)
                if fo is not None and fo + 4 <= len(d):
                    val, = struct.unpack_from('<I', d, fo)
                    s = cstr(val)
                    note = f'   ; ={val:#x}' + (f' "{s}"' if s else '')
            print(f"    {ins.address:#x}: {ins.mnemonic:8} {ins.op_str}{note}")
        lo = d.find(lit, lo + 4)
