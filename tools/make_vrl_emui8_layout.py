#!/usr/bin/env python3
# 按 EMUI8 活分区表序重排 vrl 证书槽。
# 根因(离线逐字节证明):vrl 槽 = LK 分区数组序号*4096,数组 = [xloader,ptable]+GPT 各项(即 GPT 序号+2)。
#   LK 0xa6ddc 按名字查序号(strncmp 0x24,stride 0x40),GetVrlOffset(0x1285e0) 再 index<<12。
#   B186 GPT 反验 8/8 吻合;EMUI8 fastboot GPT4->LK6->0x6000 == xloader 读 LK 证书处(独立佐证)。
#   EMUI8 重排了分区:fw_hifi GPT25->LK27->0x1b000(旧 B186 位置是 0x1c000)。
#   之前 vrl_emui8certs 按 B186 老位置放证书 => LK 校验 hifi 去 0x1b000 取到 sensorhub 证书 => Func 8。
# 本脚本:全 256KB 清零,把 13 个 EMUI8 真证书包头的[:4096]放到各自 EMUI8 槽。不伪造签名。
import struct, hashlib, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GPT = os.path.join(ROOT, "dd_set", "efi.img")
PKG = os.path.join(ROOT, "emui8_b379")
OUT = os.path.join(ROOT, "fix_vrl", "vrl_emui8_layout.img")
SIZE = 262144

def gpt_index():
    b = open(GPT, "rb").read()
    i = b.find(b"EFI PART"); hdr = b[i:i+92]
    num = struct.unpack_from("<I", hdr, 80)[0]; esize = struct.unpack_from("<I", hdr, 84)[0]
    ent = i + 512
    d = {}
    for k in range(num):
        e = b[ent+k*esize:ent+(k+1)*esize]
        if e[:16] == b"\x00"*16: continue
        nm = e[56:128].decode("utf-16-le").split("\x00")[0]
        d[nm] = k
    return d

# EMUI8 里 vrl 签名(magic e291f358)的镜像;xloader 无 GPT 槽(BootROM 管),不入 vrl。
SIGNED = ["fw_lpm3","fastboot","teeos","trustfirmware","sensorhub","fw_hifi",
          "erecovery_kernel","kernel","dts","modem_fw","recovery_vbmeta",
          "erecovery_vbmeta","vbmeta"]

def main():
    gpt = gpt_index()
    img = bytearray(SIZE)
    placed = []
    for n in SIGNED:
        p = os.path.join(PKG, n + ".img")
        h = open(p, "rb").read(4096)
        m = struct.unpack_from("<I", h, 0x80)[0]
        if m != 0xe291f358:
            print("REFUSE %s magic=%08x not a vrl cert" % (n, m)); sys.exit(3)
        if n not in gpt:
            print("REFUSE %s not in EMUI8 GPT" % n); sys.exit(3)
        slot = (gpt[n] + 2) * 4096
        if slot + 4096 > SIZE:
            print("REFUSE %s slot %x out of range" % (n, slot)); sys.exit(3)
        if any(img[slot:slot+4096]):
            print("REFUSE %s slot %x collision" % (n, slot)); sys.exit(3)
        img[slot:slot+4096] = h
        placed.append((slot, n, gpt[n]))
    # 校验:每个非零块 magic 全对
    bad = 0
    for off in range(0, SIZE, 4096):
        blk = img[off:off+4096]
        if any(blk):
            if struct.unpack_from("<I", blk, 0x80)[0] != 0xe291f358: bad += 1
    if bad:
        print("REFUSE %d bad blocks" % bad); sys.exit(3)
    open(OUT, "wb").write(img)
    sha = hashlib.sha256(img).hexdigest()
    print("placed %d certs:" % len(placed))
    for slot, n, g in sorted(placed):
        print("  slot %05x  lk%2d gpt%2d  %s" % (slot, g+2, g, n))
    print("nonzero blocks=%d bad=%d" % (sum(1 for o in range(0,SIZE,4096) if any(img[o:o+4096])), bad))
    print("OUT %s size=%d" % (OUT, len(img)))
    print("sha256=%s" % sha)
    # 与当前闪存现状(vrl_emui8certs)对比
    cur = os.path.join(ROOT, "fix_vrl", "vrl_emui8certs.img")
    if os.path.exists(cur):
        c = open(cur, "rb").read()
        diff = sum(1 for a, b2 in zip(img, c) if a != b2)
        print("vs current on-flash vrl_emui8certs: diff=%d bytes" % diff)

if __name__ == "__main__":
    main()