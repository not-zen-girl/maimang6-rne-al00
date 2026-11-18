import re, struct, sys
from capstone import *
from capstone.arm_const import *

IMG = "rb186/xloader.img"


def load(path=IMG):
    return open(path, "rb").read()


def strings(b, minlen=4):
    out = {}
    for m in re.finditer(rb"[ -~\n]{%d,}\x00" % minlen, b):
        s = m.group()[:-1]
        out[m.start()] = s.rstrip(b"\n").decode("ascii", "replace")
    return out


class XDis:
    """ARM32 Thumb disassembler for the xloader, link base 0."""

    def __init__(self, b, base=0):
        self.b = b
        self.base = base
        self.md = Cs(CS_ARCH_ARM, CS_MODE_THUMB | CS_MODE_LITTLE_ENDIAN)
        self.md.detail = True
        self.md.skipdata = True
        self.strs = strings(b)

    def run(self, start, count):
        return list(self.md.disasm(self.b[start:start + count * 4], self.base + start))

    def refs(self, start, end):
        """Absolute string references, via MOVW/MOVT pairs and LDR-literal + ADD Rd,PC.

        A bare LDR-literal value is usually a link-base-relative offset to a global,
        not a string pointer; only the ADD Rd,PC form resolves to a real address.
        """
        hits = []
        movw = {}
        pend = {}
        for ins in self.md.disasm(self.b[start:end], self.base + start):
            if ins.id == 0:
                continue
            m, ops = ins.mnemonic, ins.operands
            if m.startswith("movw") and len(ops) == 2 and ops[1].type == ARM_OP_IMM:
                movw[ops[0].reg] = ops[1].imm & 0xFFFF
                continue
            if m.startswith("movt") and len(ops) == 2 and ops[1].type == ARM_OP_IMM:
                rd = ops[0].reg
                t = ((ops[1].imm & 0xFFFF) << 16) | movw.get(rd, 0)
                movw.pop(rd, None)
                off = t - self.base
                if 0 <= off < len(self.b):
                    hits.append((ins.address, "movw/movt", "0x%08x" % t, t, off))
                continue
            if m == "ldr" and len(ops) == 2 and ops[1].type == ARM_OP_MEM \
                    and ops[1].mem.base == ARM_REG_PC and ops[1].mem.index == 0:
                pool = ((ins.address + 4) & ~3) + ops[1].mem.disp
                if 0 <= pool - self.base <= len(self.b) - 4:
                    pend[ops[0].reg] = (struct.unpack_from("<I", self.b, pool - self.base)[0],
                                        ins.address, pool)
                continue
            if m == "add" and len(ops) == 2 and ops[1].type == ARM_OP_REG \
                    and ops[1].reg == ARM_REG_PC and ops[0].reg in pend:
                lit, ldr_a, pool = pend.pop(ops[0].reg)
                t = lit + ins.address + 4
                off = t - self.base
                if 0 <= off < len(self.b):
                    hits.append((ins.address, "ldr+addpc", "lit 0x%x @0x%x" % (lit, pool), t, off))
                continue
            for op in ops:
                if op.type == ARM_OP_IMM and m in ("adr", "adr.w"):
                    off = op.imm - self.base
                    if 0 <= off < len(self.b):
                        hits.append((ins.address, m, ins.op_str, op.imm, off))
        return hits

    def label(self, off):
        if off in self.strs:
            return "STR %r" % self.strs[off]
        for s in sorted(self.strs):
            if s < off < s + len(self.strs[s]) + 2:
                return "STR+0x%x %r" % (off - s, self.strs[s][off - s:])
        return ""


if __name__ == "__main__":
    b = load()
    d = XDis(b)
    if len(sys.argv) > 1 and sys.argv[1] == "refs":
        lo = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0
        hi = int(sys.argv[3], 16) if len(sys.argv) > 3 else len(b)
        for a, m, o, t, off in d.refs(lo, hi):
            lab = d.label(off)
            if lab:
                print("0x%05x  %-8s %-28s -> 0x%05x  %s" % (a, m, o, off, lab))
    else:
        start = int(sys.argv[1], 16)
        n = int(sys.argv[2]) if len(sys.argv) > 2 else 60
        for ins in d.run(start, n):
            if ins.id == 0:
                print("0x%05x  .byte %s" % (ins.address, ins.bytes.hex()))
                continue
            extra = ""
            for op in ins.operands:
                if op.type == ARM_OP_IMM:
                    off = op.imm - d.base
                    if 0 <= off < len(b):
                        extra = "   ; " + (d.label(off) or "off 0x%05x" % off)
                elif op.type == ARM_OP_MEM and op.mem.base == ARM_REG_PC:
                    pc = (ins.address + 4) & ~3
                    t = pc + op.mem.disp
                    if 0 <= t < len(b) - 3:
                        W = struct.unpack_from("<I", b, t)[0]
                        extra = "   ; [0x%05x] = 0x%08x %s" % (t, W, d.label(W))
            print("0x%05x  %-9s %-30s%s" % (ins.address, ins.mnemonic, ins.op_str, extra))