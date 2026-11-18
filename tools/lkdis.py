"""Disassemble rb186/fastboot.img at link base 0 (proven: RAM addr == file offset).

Resolves ADRP+ADD/LDR pairs to file offsets and prints the string/pointer they hit,
so branch targets and log messages are readable without guessing the link base.
ASCII output only.
"""
import argparse
import struct
import sys

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN
from capstone.arm64 import ARM64_INS_ADRP, ARM64_INS_ADD, ARM64_INS_LDR

IMG = "rb186/fastboot.img"


def load(path=IMG):
    return open(path, "rb").read()


def cstr(b, off, limit=160):
    if not (0 <= off < len(b)):
        return None
    end = b.find(b"\0", off, off + limit)
    if end < 0:
        return None
    s = b[off:end]
    if not s or any(c < 32 or c > 126 for c in s):
        return None
    return s.decode("ascii")


def u64(b, off):
    if 0 <= off <= len(b) - 8:
        return struct.unpack_from("<Q", b, off)[0]
    return None


class Dis:
    def __init__(self, b):
        self.b = b
        self.md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
        self.md.detail = True
        self.regs = {}

    def run(self, start, count):
        out = []
        for ins in self.md.disasm(self.b[start:start + count * 4], start):
            note = ""
            m, ops = ins.mnemonic, ins.operands
            if ins.id == ARM64_INS_ADRP:
                self.regs[ops[0].reg] = ops[1].imm
            elif ins.id in (ARM64_INS_ADD, ARM64_INS_LDR) and len(ops) >= 2:
                base = None
                if ops[1].type == 1 and ops[1].reg in self.regs:
                    base = self.regs[ops[1].reg]
                if base is not None:
                    if ins.id == ARM64_INS_ADD and ops[-1].type == 2:
                        tgt = base + ops[-1].imm
                        self.regs[ops[0].reg] = tgt
                        note = self.describe(tgt)
                    elif ins.id == ARM64_INS_LDR and ops[-1].type == 3:
                        tgt = base + ops[-1].mem.disp
                        note = self.describe(tgt, deref=True)
                    elif ins.id == ARM64_INS_LDR and len(ops) == 2 and ops[1].type == 3:
                        tgt = base + ops[1].mem.disp
                        note = self.describe(tgt, deref=True)
            elif m in ("bl", "b", "blr") and ops and ops[0].type == 2:
                note = "-> 0x%x" % ops[0].imm
            if ins.id != ARM64_INS_ADRP:
                for o in ops:
                    if o.type == 1 and o.access & 2:
                        self.regs.pop(o.reg, None)
            out.append((ins.address, ins.mnemonic, ins.op_str, note))
        return out

    def describe(self, tgt, deref=False):
        s = cstr(self.b, tgt)
        if s:
            return "= 0x%x \"%s\"" % (tgt, s)
        if deref:
            v = u64(self.b, tgt)
            if v is not None and 0 < v < len(self.b):
                s2 = cstr(self.b, v)
                if s2:
                    return "[0x%x] = 0x%x \"%s\"" % (tgt, v, s2)
                return "[0x%x] = 0x%x" % (tgt, v)
            if v is not None:
                return "[0x%x] = 0x%x" % (tgt, v)
        return "= 0x%x" % tgt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("start", help="hex file offset == RAM address")
    ap.add_argument("-n", type=int, default=60)
    ap.add_argument("--img", default=IMG)
    a = ap.parse_args()
    b = load(a.img)
    d = Dis(b)
    for addr, m, ops, note in d.run(int(a.start, 16), a.n):
        print("0x%06x  %-8s %-34s %s" % (addr, m, ops, note))


if __name__ == "__main__":
    sys.exit(main())