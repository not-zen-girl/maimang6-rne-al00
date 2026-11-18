#!/usr/bin/env bash
# Root stage A: wait for the BootROM COM1.0 download port (user testpoints), RAM-load
# the official 5.1 b186p pair (NO flash writes), then prove the channel is writable and
# the EMUI8 GPT is live, and gate the Magisk-patched ramdisk. STOPS before any flash.
# The actual `flash ramdisk` is a separate, explicitly-approved step (stage B).
set -u
cd "$(dirname "$0")/.." || exit 1
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
IMG="out_check/magisk_patched-31100_T0fcO.img"
IMG_SHA="10728810fab3e47dcecf4f1b5e6c162efac6e0c3977a31170b32a74ebd6558d0"
IMG_SZ=16777216
OUT="out_check/rootA_$(date +%H%M%S)"; mkdir -p "$OUT"
exec >> >(tee "$OUT/run.log") 2>&1
echo "[*] $(date +%H:%M:%S) root stage A  log=$OUT  (no flash writes here)"

ids() { powershell -NoProfile -ExecutionPolicy Bypass -File tools/phone_ids.ps1 2>/dev/null | tr -d '\r' | tr '\n' ' '; }
fb() { local t="$1"; shift; local f="$OUT/cmd_$(echo "$*" | tr ' /:' '___').log"; timeout "$t" "$FB" "$@" </dev/null >"$f" 2>&1; tr -d '\000\r' < "$f"; }
fbr() { local t="$1"; shift; local o k; for k in 1 2 3; do o=$(fb "$t" "$@"); [ -n "$(echo "$o" | tr -d '[:space:]')" ] && { echo "$o"; return 0; }; done; echo "$o"; return 1; }

echo "[=] watching bus for COM1.0 (PID_3609), max 300s -- please testpoint now"
found=0
for i in $(seq 1 30); do
  s=$(ids)
  case "$s" in
    *PID_3609*) if ! "$FB" devices 2>/dev/null | grep -q fastboot; then echo "[+] t+$((i*10))s COM1.0 download port: $s"; found=1; break; fi;;
  esac
  [ $((i % 3)) -eq 0 ] && echo "  t+$((i*10))s waiting: [$s]"
  sleep 10
done
if [ "$found" != 1 ]; then echo "[-] no COM1.0 within 300s -- nothing sent, nothing written"; exit 1; fi
sleep 3

echo "[=] RAM-load b186p (rollback_b186 xloader+LK, with prefix) -- no flash writes"
bash tools/pair_split.sh b186p
echo "[=] pair_split finished, probing channel (read-only)"

if ! "$FB" devices 2>/dev/null | grep -q fastboot; then echo "[x] no fastboot after RAM load -- STOP"; exit 4; fi
echo "[=] channel: $("$FB" devices 2>/dev/null | tr '\n' ' ')"

mds=$(fbr 15 getvar max-download-size); echo "$mds" | sed 's/^/    mds| /'
echo "$mds" | grep -q '471859200' || { echo "[x] max-download-size not 471859200 -- STOP"; exit 5; }

di=$(fbr 20 oem device info); echo "$di" | sed 's/^/    lock| /'
echo "$di" | grep -q 'FB LockState: UNLOCKED' || { echo "[x] channel NOT UNLOCKED -- refusing to write"; exit 6; }
echo "[+] FB LockState UNLOCKED -- channel may write"

: > "$OUT/ptn.txt"
for v in kernel system boot ramdisk; do
  o=$(fbr 15 getvar "storage:$v"); echo "storage:$v -> $(echo "$o" | tr '\n' ' ')" >> "$OUT/ptn.txt"
done
sed 's/^/    ptn| /' "$OUT/ptn.txt"
grep -q 'storage:kernel ->.*1b800000' "$OUT/ptn.txt" || { echo "[x] kernel not at EMUI8 address -- stale table, STOP"; exit 7; }
grep -q 'storage:system ->.*4d800000' "$OUT/ptn.txt" || { echo "[x] system not at EMUI8 address -- stale table, STOP"; exit 7; }
echo "[+] live partition table IS the EMUI8 GPT"

echo "[=] gate patched ramdisk (size + sha256 + partition capacity)"
sz=$(wc -c < "$IMG"); h=$(sha256sum "$IMG" | cut -d' ' -f1)
echo "    file=$IMG size=$sz/$IMG_SZ sha=$h"
[ "$sz" = "$IMG_SZ" ] || { echo "[x] size mismatch -- STOP"; exit 8; }
[ "$h" = "$IMG_SHA" ] || { echo "[x] sha mismatch -- STOP"; exit 8; }
cap=$(python -c "import json;m=json.load(open('dd_set/manifest.json'));e=[x for x in m if x['name']=='ramdisk'][0];print(e['sectors']*512)")
echo "    ramdisk partition capacity=$cap B (manifest sectors*512)"
[ "$IMG_SZ" -le "$cap" ] || { echo "[x] image larger than partition -- STOP"; exit 8; }
echo "[+] gate PASS: patched ramdisk fits the ramdisk partition exactly"
echo "[*] stage A done $(date +%H:%M:%S). Channel WRITABLE + EMUI8 table live + image gated."
echo "[*] NEXT (separate approval): flash ramdisk $IMG  ->  Writing OKAY  ->  reboot  ->  verify root"