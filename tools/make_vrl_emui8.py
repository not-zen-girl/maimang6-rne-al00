#!/usr/bin/env python3
"""Build fix_vrl/vrl_emui8certs.img: vrl_original with the per-image cert slots
refreshed to the EMUI8 B379 package headers.

Evidence (2026-11-17 ~23:0x): vrl stores a copy of each signed image's 4096-byte
package header; slot 0x6000 == emui8 fastboot header EXACT after the 22:35 write,
every other active slot differs from its EMUI8 header only in 0x74c..0x87e (the
signature/cert block). On-flash LK verifies fw_hifi first -> ERROR MODE Func 8 /
Error 1 (security verify failed) because those slots still hold B186-era certs.

Only the listed slots change; source bytes are the verified package headers.
Slots with boot flg 0 (recovery/recovery2/vbmeta trio) and everything else stay
byte-identical.
"""
import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SLOTS = [
    (0x4000, "fw_lpm3"),
    (0x18000, "teeos"),
    (0x19000, "teeos"),
    (0x1A000, "trustfirmware"),
    (0x1B000, "sensorhub"),
    (0x1C000, "fw_hifi"),
    (0x1D000, "kernel"),
    (0x1F000, "dts"),
    (0x20000, "modem_fw"),
    (0x23000, "dts"),
    (0x25000, "modem_fw"),
]
BASE = os.path.join(ROOT, "fix_vrl", "vrl_original.img")
BASE_SHA = "4988f47970d124ecf4ef032a9f6b379b2aa73627a4cc3b90e56c8d04a863115c"
OUT = os.path.join(ROOT, "fix_vrl", "vrl_emui8certs.img")


def sha(b):
    return hashlib.sha256(b).hexdigest()


def main():
    base = open(BASE, "rb").read()
    if len(base) != 262144 or sha(base) != BASE_SHA:
        print("[x] base vrl_original missing/corrupt -- refuse")
        return 3
    new = bytearray(base)
    for off, name in SLOTS:
        hdr = open(os.path.join(ROOT, "emui8_b379", name + ".img"), "rb").read(4096)
        if len(hdr) != 4096:
            print("[x] short header", name)
            return 3
        old = bytes(new[off:off + 4096])
        d = [i for i in range(4096) if old[i] != hdr[i]]
        if not d:
            print("[=] %s @%#x already EMUI8" % (name, off))
            continue
        if max(d) > 0x87E and name != "kernel":
            print("[x] %s @%#x diff outside cert block -- refuse" % (name, off))
            return 4
        new[off:off + 4096] = hdr
        print("[+] %s @%#x  %d bytes refreshed (%#x..%#x)" % (name, off, len(d), d[0], d[-1]))
    changed = sum(1 for a, b in zip(base, new) if a != b)
    open(OUT, "wb").write(bytes(new))
    print("[*] changed bytes: %d / 262144" % changed)
    print("[*] out sha256: %s" % sha(bytes(new)))
    print("[*] restore image stays fix_vrl/vrl_original.img sha %s" % BASE_SHA)
    return 0


if __name__ == "__main__":
    sys.exit(main())