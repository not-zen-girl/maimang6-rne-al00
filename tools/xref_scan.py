"""Sliding-window ADRP+ADD/LDR xref scanner (manual decode, no linear-disasm drift).

Usage: python tools/xref_scan.py <hextarget> [hextarget ...]
Prints every code site that materialises one of the target addresses.
"""
import struct
import sys

b = open('rb186/fastboot.img', 'rb').read()
N = len(b)
targets = {int(a, 16) for a in sys.argv[1:]}


def sext(v, bits):
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


hits = {}
for f in range(0, N - 16, 4):
    ins = struct.unpack_from('<I', b, f)[0]
    if (ins & 0x9F000000) != 0x90000000:
        continue
    immlo = (ins >> 29) & 3
    immhi = (ins >> 5) & 0x7FFFF
    page = (f & ~0xFFF) + (sext((immhi << 2) | immlo, 21) << 12)
    rd = ins & 31
    for k in range(1, 7):
        g = f + 4 * k
        if g + 4 > N:
            break
        j = struct.unpack_from('<I', b, g)[0]
        rn = (j >> 5) & 31
        tgt = None
        if (j & 0xFF000000) == 0x91000000 and rn == rd:
            sh = (j >> 22) & 3
            if sh in (0, 1):
                tgt = page + (((j >> 10) & 0xFFF) << (12 if sh else 0))
        elif (j & 0xFFC00000) == 0xF9400000 and rn == rd:
            tgt = page + (((j >> 10) & 0xFFF) * 8)
        elif (j & 0xFFC00000) == 0xB9400000 and rn == rd:
            tgt = page + (((j >> 10) & 0xFFF) * 4)
        if tgt is not None and tgt in targets:
            hits.setdefault(tgt, []).append((f, g))
            break
        # stop if rd is overwritten by something else
        if (j & 0x1F) == rd and (j & 0x9F000000) != 0x90000000:
            d = j & 0xFF000000
            if d not in (0x91000000, 0xF9000000, 0xB9000000, 0x90000000):
                break


def s_at(o):
    e = b.find(b'\0', o, o + 120)
    if e < 0:
        return ''
    s = b[o:e]
    if s and all(32 <= c < 127 or c == 10 for c in s):
        return repr(s.decode('ascii', 'replace'))
    return ''


for t in sorted(targets):
    hs = hits.get(t, [])
    print('%08x %-46s %d refs' % (t, s_at(t), len(hs)))
    for f, g in hs:
        print('    adrp@%06x  op@%06x' % (f, g))