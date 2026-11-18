#!/usr/bin/env bash
# Root stage B: flash the Magisk-patched ramdisk to the ramdisk partition (ONE write),
# then reboot and observe. Re-verifies the writable channel + EMUI8 GPT + image gate
# immediately before writing. Any failure stops with NO reboot. Forbidden partitions
# (efuse oeminfo frp nvme modemnvm_* modem_om modem_secure secure_storage userdata) untouched.
set -u
cd "$(dirname "$0")/.." || exit 1
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
ADB="./platform-tools/adb.exe"
IMG="out_check/magisk_patched-31100_T0fcO.img"
IMG_SHA="10728810fab3e47dcecf4f1b5e6c162efac6e0c3977a31170b32a74ebd6558d0"
IMG_SZ=16777216
OUT="out_check/rootB_$(date +%H%M%S)"; mkdir -p "$OUT"
exec >> >(tee "$OUT/run.log") 2>&1
echo "[*] $(date +%H:%M:%S) root stage B  log=$OUT"

ids() { powershell -NoProfile -ExecutionPolicy Bypass -File tools/phone_ids.ps1 2>/dev/null | tr -d '\r' | tr '\n' ' '; }
fb() { local t="$1"; shift; local f="$OUT/cmd_$(echo "$*" | tr ' /:' '___').log"; timeout "$t" "$FB" "$@" </dev/null >"$f" 2>&1; tr -d '\000\r' < "$f"; }
fbr() { local t="$1"; shift; local o k; for k in 1 2 3; do o=$(fb "$t" "$@"); [ -n "$(echo "$o" | tr -d '[:space:]')" ] && { echo "$o"; return 0; }; done; echo "$o"; return 1; }

"$FB" devices 2>/dev/null | grep -q fastboot || { echo "[x] no fastboot channel -- STOP"; exit 4; }
echo "[=] channel: $("$FB" devices 2>/dev/null | tr '\n' ' ')"
mds=$(fbr 15 getvar max-download-size); echo "$mds" | sed 's/^/    mds| /'
echo "$mds" | grep -q '471859200' || { echo "[x] pre-flight no answer -- STOP, no write"; exit 5; }
di=$(fbr 20 oem device info); echo "$di" | sed 's/^/    lock| /'
echo "$di" | grep -q 'FB LockState: UNLOCKED' || { echo "[x] NOT UNLOCKED -- STOP, no write"; exit 6; }
echo "[+] channel UNLOCKED"

probe_table() { : > "$OUT/ptn_$1.txt"; for v in kernel system boot ramdisk; do o=$(fbr 15 getvar "storage:$v"); echo "storage:$v -> $(echo "$o" | tr '\n' ' ')" >> "$OUT/ptn_$1.txt"; done; sed 's/^/    ptn| /' "$OUT/ptn_$1.txt"; }
is_emui8() { grep -q 'storage:kernel ->.*1b800000' "$OUT/ptn_$1.txt" && grep -q 'storage:system ->.*4d800000' "$OUT/ptn_$1.txt"; }

echo "[=] BEFORE flip (read-only name resolution)"
probe_table before
if ! is_emui8 before; then
  echo "[=] live table is B186 -- flipping ptable to EMUI8 GPT (proven 22:19 hot-reload)"
  PT="dd_set/efi.img"; PT_SHA="9cbb0b5936d1e8702d8ed67b2e101306728c1d3d892e003ef34b915e4ee7f728"; PT_SZ=17408
  psz=$(wc -c < "$PT"); ph=$(sha256sum "$PT" | cut -d' ' -f1)
  echo "[=] ptable gate: size=$psz/$PT_SZ sha=$ph"
  [ "$psz" = "$PT_SZ" ] && [ "$ph" = "$PT_SHA" ] || { echo "[x] ptable gate FAIL -- STOP, no write"; exit 8; }
  echo "[w] $(date +%H:%M:%S) flash ptable  ($PT, $psz B)"
  po=$(fb 60 flash ptable "$PT"); echo "$po" | sed 's/^/    /'
  echo "$po" | grep -q "Writing 'ptable'.*OKAY" || { echo "[x] ptable no Writing OKAY -- STOP, no reboot"; exit 6; }
  echo "[+] ptable Writing OKAY -- re-probe for hot-reload"
  probe_table after
  is_emui8 after || { echo "[x] table did not hot-reload to EMUI8 -- STOP, no reboot"; exit 7; }
else
  echo "[+] live table already EMUI8 -- no ptable write needed"
fi
echo "[+] EMUI8 GPT live (kernel@1b800000 system@4d800000)"

sz=$(wc -c < "$IMG"); h=$(sha256sum "$IMG" | cut -d' ' -f1)
echo "[=] gate: size=$sz/$IMG_SZ sha=$h"
[ "$sz" = "$IMG_SZ" ] && [ "$h" = "$IMG_SHA" ] || { echo "[x] image gate FAIL -- STOP, no write"; exit 8; }
echo "[+] image gate PASS"

echo "[w] $(date +%H:%M:%S) flash ramdisk  ($IMG, $sz B)"
t0=$(date +%s%N); o=$(fb 300 flash ramdisk "$IMG"); t1=$(date +%s%N); el=$(( (t1-t0)/1000000 ))
echo "    elapsed=${el}ms"; echo "$o" | sed 's/^/    /'
if echo "$o" | grep -qi 'not allowed'; then echo "[x] refused -- STOP, no reboot"; exit 5; fi
if echo "$o" | grep -qiE 'partition is not exist|unknown partition|no such partition'; then echo "[x] name not resolved -- STOP, no reboot"; exit 7; fi
if echo "$o" | grep -qiE 'FAILED|remote error|too large'; then echo "[x] FAILED -- STOP, no reboot"; exit 6; fi
if ! echo "$o" | grep -q "Writing 'ramdisk'.*OKAY"; then echo "[x] no Writing OKAY -- STOP, no reboot"; exit 6; fi
if echo "$o" | grep -q "Writing 'ramdisk'.*OKAY \[  0.000s\]"; then echo "[!] 0.000s ACK-only -- STOP, no reboot"; exit 8; fi
echo "[+] ramdisk Writing OKAY"

echo "[w] $(date +%H:%M:%S) reboot"
fb 25 reboot | sed 's/^/    /'
echo "[=] bounded observation 300s (screen is the truth)"
for i in $(seq 1 30); do
  sleep 10; s=$(ids)
  case "$s" in
    *PID_3609*) tag="COM1.0 download port";;
    *PID_D00D*) tag="FASTBOOT";;
    *PID_107E*) tag="BOOTED (system)";;
    "")         tag="off bus";;
    *)          tag="other enumeration";;
  esac
  a=$("$ADB" devices 2>/dev/null | grep -w device | tr '\n' ' ')
  echo "  t+$((i*10))s  $tag  [$s]  adb=[$a]"
  case "$tag" in
    "BOOTED (system)") echo "[+] phone booted -- check screen for EMUI8 + Magisk"; break;;
    FASTBOOT) echo "[!] fell to fastboot -- boot chain rejected patched ramdisk"; break;;
    "COM1.0 download port") echo "[!] fell to COM1.0 -- mismatch"; break;;
  esac
done
echo "[*] stage B done $(date +%H:%M:%S). Verify root next: adb shell su -c id"