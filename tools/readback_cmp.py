"""Read partitions back over the zero-write raw client and diff them against rb186/.

Fetches the live GPT first so offsets/lengths come from the phone, not from a guess.
Every command sent is on fbraw's read-only whitelist.
"""
import argparse
import os
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BOOT_CRITICAL = ["fw_lpm3", "trustfirmware", "teeos", "sensorhub", "fw_hifi",
                 "dts", "boot", "vbmeta", "splash2", "misc", "version"]
MAXLEN = 0x400000


def strip_okay(b):
    if b[:5] == b"OKAY\0":
        b = b[5:]
    if b[-5:] == b"OKAY\0":
        b = b[:-5]
    return b


def gpt_entries(blob):
    out = {}
    for i in range(len(blob) // 128):
        e = blob[i * 128:(i + 1) * 128]
        if e[:16] == b"\0" * 16:
            continue
        s, l = struct.unpack_from("<QQ", e, 32)
        out[e[56:128].decode("utf-16-le").rstrip("\0")] = (s * 512, (l - s + 1) * 512)
    return out


def run(cmds, outdir, seconds):
    argv = [sys.executable, os.path.join(HERE, "fbraw.py"),
            "--outdir", outdir, "--seconds", str(seconds)]
    for c in cmds:
        argv += ["--cmd", c]
    p = subprocess.run(argv, cwd=ROOT, capture_output=True)
    sys.stdout.write(p.stdout.decode("ascii", "backslashreplace"))
    if p.returncode:
        sys.stdout.write(p.stderr.decode("ascii", "backslashreplace"))
    return p.returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="*")
    ap.add_argument("--boot-critical", action="store_true")
    ap.add_argument("--ref", default="rb186")
    ap.add_argument("--seconds", type=float, default=20.0)
    ap.add_argument("--head", type=lambda x: int(x, 16), default=0x10000,
                    help="bytes to compare when no reference image exists")
    a = ap.parse_args()
    names = list(a.names)
    if a.boot_critical:
        names += [n for n in BOOT_CRITICAL if n not in names]
    if not names:
        ap.error("give partition names or --boot-critical")

    outdir = os.path.join("out_check", "cmp_%s" % time.strftime("%H%M%S"))
    os.makedirs(os.path.join(ROOT, outdir), exist_ok=True)

    print("### step 1: live GPT")
    run(["getvar storage:ptable", "upload_storage:400:4000"], outdir, a.seconds)
    gp = os.path.join(ROOT, outdir, "upload_storage_400_4000.bin")
    if not os.path.exists(gp):
        print("[x] no GPT capture")
        return 1
    parts = gpt_entries(strip_okay(open(gp, "rb").read()))
    print("live GPT: %d named partitions" % len(parts))

    cmds, plan = [], []
    for n in names:
        if n not in parts:
            print("[!] %s not in live GPT, skipped" % n)
            continue
        start, plen = parts[n]
        ref = os.path.join(ROOT, a.ref, n + ".img")
        rlen = os.path.getsize(ref) if os.path.exists(ref) else a.head
        ln = min(rlen, plen, MAXLEN)
        if start + ln > 0xFFFFFFFF:
            print("[!] %s start 0x%x too high for the 8-digit field, skipped" % (n, start))
            continue
        cmds += ["getvar storage:%s" % n, "upload_storage:%x:%x" % (start, ln)]
        plan.append((n, start, ln, ref if os.path.exists(ref) else None))

    print("\n### step 2: read back %d partitions" % len(plan))
    run(cmds, outdir, a.seconds)

    print("\n### step 3: compare against %s/" % a.ref)
    bad = 0
    for n, start, ln, ref in plan:
        tag = "upload_storage_%x_%x" % (start, ln)
        p = os.path.join(ROOT, outdir, tag + ".bin")
        if not os.path.exists(p):
            print("  %-16s NO CAPTURE" % n)
            bad += 1
            continue
        got = strip_okay(open(p, "rb").read())
        if len(got) != ln:
            print("  %-16s SHORT %d/%d bytes" % (n, len(got), ln))
            bad += 1
            continue
        if ref is None:
            nz = sum(1 for c in got if c)
            print("  %-16s %7d B  no ref  nonzero=%.1f%%  head=%s"
                  % (n, len(got), 100.0 * nz / len(got), got[:16].hex()))
            continue
        want = open(ref, "rb").read()[:ln]
        if got == want:
            print("  %-16s %7d B  IDENTICAL to %s/%s.img" % (n, len(got), a.ref, n))
        else:
            diff = [i for i in range(ln) if got[i] != want[i]]
            nz = sum(1 for c in got if c)
            print("  %-16s %7d B  MISMATCH %d bytes (first 0x%x last 0x%x) nonzero=%.1f%%"
                  % (n, len(got), len(diff), diff[0], diff[-1], 100.0 * nz / len(got)))
            print("      flash head=%s" % got[:24].hex())
            print("      ref   head=%s" % want[:24].hex())
            bad += 1
    print("\noutdir=%s  mismatches/missing=%d  (zero-write)" % (outdir, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())