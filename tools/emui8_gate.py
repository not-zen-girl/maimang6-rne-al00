#!/usr/bin/env python
# Gate every artifact of the EMUI8 B379 staged fastboot plan before any write.
# Anchors: dd_set/plan.txt (on-flash payload sector counts + sha256),
#          emui8_b379/SHA256SUMS.txt (package form),
#          dd_set/efi.img (target GPT capacities).
import hashlib, json, os, struct, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
OUT = sys.argv[1] if len(sys.argv) > 1 else 'out_check/emui8_gate'
os.makedirs(OUT, exist_ok=True)

FORBID = {'efuse', 'oeminfo', 'frp', 'nvme', 'modemnvm_factory', 'modemnvm_backup',
          'modemnvm_img', 'modemnvm_system', 'modemnvm_update', 'modem_om',
          'modem_secure', 'secure_storage', 'userdata', 'vrl_backup'}

lines = []
bad = 0


def w(s):
    lines.append(s)


def sha_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        while True:
            b = f.read(1 << 22)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


# ---- anchors -------------------------------------------------------------
plan = {}
for ln in open('dd_set/plan.txt', encoding='utf-8'):
    ln = ln.strip()
    if not ln or ln.startswith('#'):
        continue
    p = ln.split('|')
    phase, name, src, bs, seek, count, want = p[0], p[1], p[2], int(p[3]), int(p[4]), int(p[5]), p[6]
    plan[name] = dict(phase=int(phase), bs=bs, seek=seek, count=count,
                      size=bs * count, sha=want)

pkgsha = {}
for ln in open('emui8_b379/SHA256SUMS.txt', encoding='utf-8'):
    ln = ln.strip()
    if not ln:
        continue
    h, n = ln.split()
    pkgsha[n.lstrip('*')] = h

g = open('dd_set/efi.img', 'rb').read()
cap = {}
entries = 0
for i in range(128):
    e = g[1024 + i * 128:1152 + i * 128]
    if e[:16] == b'\0' * 16:
        continue
    f, l = struct.unpack('<QQ', e[32:48])
    nm = e[56:128].decode('utf-16-le').rstrip('\0')
    cap[nm] = (l - f + 1) * 512
    entries += 1
w('target GPT dd_set/efi.img: %d entries, signature %s' % (entries, g[512:520].hex()))
if g[512:520] != b'EFI PART':
    w('BAD target GPT signature')
    bad = 1

# ---- sparse expander (verified by sha against plan.txt) ------------------


def sparse_expand_sha(path, want_sha, want_size):
    """Stream a (Huawei) sparse image, hash the expansion, compare to anchor."""
    h = hashlib.sha256()
    total = 0
    with open(path, 'rb') as f:
        hdr = f.read(28)
        magic, major, minor, fhs, chs, blk, tblk, tchk, csum = struct.unpack('<IHHHHIIII', hdr)
        if magic != 0xed26ff3a:
            return (False, 'not sparse magic=%08x' % magic, 0)
        f.seek(fhs)
        nchunk = 0
        while True:
            ch = f.read(chs)
            if len(ch) < chs:
                break
            # Huawei sparse 1.0 chunk header = three u32: type, block count, byte size
            ctype, csz, tsz = struct.unpack('<III', ch[:12])
            nchunk += 1
            if ctype == 0xCAC1:
                left = tsz - chs
                while left > 0:
                    b = f.read(min(left, 1 << 22))
                    if not b:
                        return (False, 'truncated raw chunk', total)
                    h.update(b)
                    total += len(b)
                    left -= len(b)
            elif ctype == 0xCAC2:
                pat = f.read(4)
                n = csz * blk
                block = (pat * (n // 4 + 1))[:n]
                h.update(block)
                total += n
            elif ctype == 0xCAC3:
                n = csz * blk
                z = bytes(1 << 20)
                left = n
                while left > 0:
                    k = min(left, len(z))
                    h.update(z[:k])
                    total += k
                    left -= k
            elif ctype == 0xCAC4:
                f.read(4)
            else:
                return (False, 'unknown chunk type %08x' % ctype, total)
        ok = (total == want_size and h.hexdigest() == want_sha
              and nchunk == tchk and total == tblk * blk)
        return (ok, 'chunks=%d/%d expanded=%d/%d sha=%s' % (nchunk, tchk, total, tblk * blk, h.hexdigest()), total)


# ---- write plan ----------------------------------------------------------
# (stage, partition, path, kind, anchor)
#   kind 'payload' -> dd_set file, gate = plan.txt size+sha
#   kind 'sparse'  -> package sparse, gate = SHA256SUMS + expansion == plan.txt
#   kind 'raw'     -> explicit size+sha
PLAN = [
    ('s1', 'ptable', 'dd_set/efi.img', 'payload', 'efi'),
    ('s2', 'erecovery_vbmeta', 'dd_set/erecovery_vbmeta.img', 'payload', 'erecovery_vbmeta'),
    ('s2', 'xloader', 'emui8_b379/xloader.img', 'raw', None),
    ('s2', 'fastboot', 'emui8_stage/fastboot_full4m.img', 'raw', None),
    ('s2', 'vrl', 'fix_vrl/vrl_original.img', 'raw', None),
    ('s2', 'dts', 'dd_set/dts.img', 'payload', 'dts'),
    ('s2', 'fw_lpm3', 'dd_set/fw_lpm3.img', 'payload', 'fw_lpm3'),
    ('s2', 'teeos', 'dd_set/teeos.img', 'payload', 'teeos'),
    ('s2', 'trustfirmware', 'dd_set/trustfirmware.img', 'payload', 'trustfirmware'),
    ('s2', 'sensorhub', 'dd_set/sensorhub.img', 'payload', 'sensorhub'),
    ('s2', 'fw_hifi', 'dd_set/fw_hifi.img', 'payload', 'fw_hifi'),
    ('s2', 'modem_fw', 'dd_set/modem_fw.img', 'payload', 'modem_fw'),
    ('s2', 'vbmeta', 'dd_set/vbmeta.img', 'payload', 'vbmeta'),
    ('s2', 'recovery_vbmeta', 'dd_set/recovery_vbmeta.img', 'payload', 'recovery_vbmeta'),
    ('s2', 'kernel', 'dd_set/kernel.img', 'payload', 'kernel'),
    ('s2', 'ramdisk', 'dd_set/ramdisk.img', 'payload', 'ramdisk'),
    ('s2', 'recovery_ramdisk', 'dd_set/recovery_ramdisk.img', 'payload', 'recovery_ramdisk'),
    ('s2', 'recovery_vendor', 'dd_set/recovery_vendor.img', 'payload', 'recovery_vendor'),
    ('s2', 'erecovery_kernel', 'dd_set/erecovery_kernel.img', 'payload', 'erecovery_kernel'),
    ('s2', 'erecovery_ramdisk', 'dd_set/erecovery_ramdisk.img', 'payload', 'erecovery_ramdisk'),
    ('s2', 'erecovery_vendor', 'dd_set/erecovery_vendor.img', 'payload', 'erecovery_vendor'),
    ('s3', 'system', 'emui8_b379/system.img', 'sparse', 'system'),
    ('s3', 'vendor', 'emui8_b379/vendor.img', 'sparse', 'vendor'),
    ('s3', 'product', 'dd_set/product.img', 'payload', 'product'),
    ('s3', 'odm', 'dd_set/odm.img', 'payload', 'odm'),
    ('s3', 'cust', 'dd_set/cust.img', 'payload', 'cust'),
    ('s3', 'version', 'dd_set/version.img', 'payload', 'version'),
    ('s3', 'preas', 'dd_set/preas.img', 'payload', 'preas'),
    ('s3', 'preavs', 'dd_set/preavs.img', 'payload', 'preavs'),
    ('s3', 'cache', 'dd_set/cache.img', 'payload', 'cache'),
]

rows = []
total = 0
for stage, part, path, kind, anchor in PLAN:
    if part in FORBID:
        w('BAD %-18s forbidden partition' % part)
        bad = 1
        continue
    if not os.path.exists(path):
        w('BAD %-18s missing %s' % (part, path))
        bad = 1
        continue
    sz = os.path.getsize(path)
    ok = False
    note = ''
    if kind == 'payload':
        e = plan[anchor]
        sha = sha_file(path)
        ok = (sz == e['size'] and sha == e['sha'])
        note = 'plan size=%d sha=%s | got size=%d sha=%s' % (e['size'], e['sha'][:16], sz, sha[:16])
        c = cap.get(part)
        fit = (c is None) or (sz <= c)
        note += ' | cap=%s fit=%s' % (c, fit)
        if not fit:
            ok = False
    elif kind == 'sparse':
        e = plan[anchor]
        sha = sha_file(path)
        pok = (sha == pkgsha[os.path.basename(path)])
        eok, enote, esz = sparse_expand_sha(path, e['sha'], e['size'])
        ok = pok and eok
        c = cap.get(part)
        fit = (c is None) or (esz <= c)
        note = 'pkg sha=%s/%s | %s | want expanded=%d sha=%s | cap=%s fit=%s' % (
            sha[:16], pkgsha[os.path.basename(path)][:16], enote, e['size'], e['sha'][:16], c, fit)
        if not fit:
            ok = False
        sz = esz
    elif kind == 'raw':
        sha = sha_file(path)
        if part == 'xloader':
            pure = open('rb379/xloader_pure.img', 'rb').read()
            b = open(path, 'rb').read()
            ok = (sz == 69568 and sha == pkgsha['xloader.img'] and b[:8] == bytes(8)
                  and b[4096:] == pure)
            note = 'size=%d sha=%s pkgsha=%s prefix8zero=%s core==rb379/xloader_pure(%d)=%s' % (
                sz, sha[:16], pkgsha['xloader.img'][:16], b[:8] == bytes(8), len(pure), b[4096:] == pure)
        elif part == 'fastboot':
            b = open(path, 'rb').read()
            core = b[:2864640]
            ok = (sz == 4194304 and hashlib.sha256(core).hexdigest() == plan['fastboot']['sha']
                  and core[:4] == bytes.fromhex('0d000014') and b[2864640:] == bytes(len(b) - 2864640))
            note = 'size=%d sha=%s core(2864640)sha=%s/%s head=%s tailzero=%s cap=%s' % (
                sz, sha[:16], hashlib.sha256(core).hexdigest()[:16], plan['fastboot']['sha'][:16],
                core[:4].hex(), b[2864640:] == bytes(len(b) - 2864640), cap.get(part))
        elif part == 'vrl':
            b = open(path, 'rb').read()
            pf = open('emui8_b379/fastboot.img', 'rb').read(4096)
            ok = (sz == 262144 and sha == '4988f47970d124ecf4ef032a9f6b379b2aa73627a4cc3b90e56c8d04a863115c'
                  and b[0x6000:0x7000] == pf and sz == cap.get('vrl'))
            note = 'size=%d sha=%s cert@0x6000==emui8pkg fastboot[:4096]=%s cap=%s' % (
                sz, sha[:16], b[0x6000:0x7000] == pf, cap.get('vrl'))
    w('%s %-18s %-6s %-38s %s' % ('OK ' if ok else 'BAD', part, stage, path, note))
    if not ok:
        bad = 1
        continue
    total += sz
    rows.append('%s\t%s\t%s\t%d' % (stage, part, path, sz))

w('')
w('total %d writes, %d bytes (%.2f GB) of payload' % (len(rows), total, total / 1073741824.0))
w('skipped by design: modemnvm_update (forbidden), userdata (forbidden), dto/preload (not shipped in package)')
w('RESULT: %s' % ('PASS' if bad == 0 else 'FAIL'))

open(os.path.join(OUT, 'gate.txt'), 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
open(os.path.join(OUT, 'plan.tsv'), 'w', encoding='utf-8').write('\n'.join(rows) + '\n')
print('\n'.join(lines).encode('ascii', 'replace').decode('ascii'))
sys.exit(bad)