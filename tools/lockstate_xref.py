"""Find who reads the fastboot lock state: xref the LockState strings across the
whole LK image (ADRP+ADD/LDR, base cancels out), then disassemble the callers."""
import re
import struct
import sys

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

b = open('rb186/fastboot.img', 'rb').read()
N = len(b)

pats = [b'FB LockState', b'UNLOCKED', b'LOCKED', b'unlock_misc', b'lock_stat',
        b'get_lockstate', b'lockstate', b'fastboot_unlock', b'fastboot_relock']
targets = {}
for p in pats:
    for m in re.finditer(re.escape(p), b):
        o = m.start()
        s = b[o:b.find(b'\0', o, o + 120)]
        if s and all(32 <= c < 127 or c == 10 for c in s):
            targets[o] = s.decode('ascii', 'replace')

print('== candidate strings ==')
for o, s in sorted(targets.items()):
    print('  %08x  %r' % (o, s))

# whole-image ADRP -> ADD/LDR resolution
md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.detail = True
md.skipdata = True
refs = {}
adrp = {}
for ins in md.disasm(b, 0):
    if ins.id == 0:
        continue
    m, ops = ins.mnemonic, ins.operands
    if m == 'adrp' and len(ops) == 2:
        adrp[ops[0].reg] = (ins.address, ops[1].imm)
    elif m in ('add', 'ldr') and len(ops) >= 2:
        src = None
        if ops[1].type == 1 and ops[1].reg in adrp:
            src = adrp[ops[1].reg]
        if src:
            f, page = src
            tgt = None
            if m == 'add' and ops[-1].type == 2:
                tgt = page + ops[-1].imm
            elif m == 'ldr' and ops[-1].type == 3:
                tgt = page + ops[-1].mem.disp
            if tgt in targets:
                refs.setdefault(tgt, []).append(f)
    if m != 'adrp':
        for o in ops:
            if o.type == 1 and (o.access & 2):
                adrp.pop(o.reg, None)

print()
print('== code references ==')
for t, fs in sorted(refs.items()):
    print('  %08x %-40r  <- %s' % (t, targets[t], ' '.join('%06x' % f for f in fs)))

if len(sys.argv) > 1:
    start = int(sys.argv[1], 16)
    cnt = int(sys.argv[2]) if len(sys.argv) > 2 else 90
    print()
    print('== disasm %06x ==' % start)
    d = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
    d.detail = True
    d.skipdata = True
    regs = {}
    for ins in d.disasm(b[start:start + cnt * 4], start):
        if ins.id == 0:
            continue
        note = ''
        m, ops = ins.mnemonic, ins.operands
        if m == 'adrp':
            regs[ops[0].reg] = ops[1].imm
        elif m in ('add', 'ldr') and len(ops) >= 2 and ops[1].type == 1 and ops[1].reg in regs:
            base = regs[ops[1].reg]
            tgt = base + ops[-1].imm if (m == 'add' and ops[-1].type == 2) else (
                base + ops[-1].mem.disp if ops[-1].type == 3 else None)
            if tgt is not None:
                if tgt in targets:
                    note = '= %08x %r' % (tgt, targets[tgt])
                else:
                    e = b.find(b'\0', tgt, tgt + 100)
                    s = b[tgt:e] if e > tgt else b''
                    if s and all(32 <= c < 127 or c == 10 for c in s) and len(s) > 3:
                        note = '= %08x %r' % (tgt, s.decode('ascii', 'replace'))
                    else:
                        note = '= %08x' % tgt
                if m == 'add':
                    regs[ops[0].reg] = tgt
        elif m in ('bl', 'b', 'blr') and ops and ops[0].type == 2:
            note = '-> %06x' % ops[0].imm
        if m != 'adrp':
            for o in ops:
                if o.type == 1 and (o.access & 2):
                    regs.pop(o.reg, None)
        print('  %06x  %-8s %-36s %s' % (ins.address, m, ins.op_str, note))