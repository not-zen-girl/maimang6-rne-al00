#!/usr/bin/env bash
# Wait (bounded) for the BootROM download port, then RAM-load the official 5.1 pair.
# Zero flash writes: pair_split only sends images to RAM. Ends by asking the LK for
# its lock state, which is the discriminator for "is this channel writable".
set -u
cd "$(dirname "$0")/.." || exit 1
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
OUT="out_check/waitcom_$(date +%H%M%S)"; mkdir -p "$OUT"
exec >> >(tee "$OUT/run.log") 2>&1
echo "[*] start $(date +%H:%M:%S) waiting for COM1.0 (PID_3609), max 1800s"
ids() { powershell -NoProfile -ExecutionPolicy Bypass -File tools/phone_ids.ps1 2>/dev/null | tr -d '\r' | tr '\n' ' '; }
found=0
for i in $(seq 1 180); do
  s=$(ids)
  case "$s" in
    *PID_3609*)
      if ! "$FB" devices 2>/dev/null | grep -q fastboot; then
        echo "[+] t+$((i*10))s download port present: $s"; found=1; break
      fi;;
  esac
  [ $((i % 6)) -eq 0 ] && echo "  t+$((i*10))s still waiting: [$s]"
  sleep 10
done
if [ "$found" != 1 ]; then echo "[-] no download port within 1800s -- nothing sent"; exit 1; fi
sleep 3
bash tools/pair_split.sh b186p
echo "[=] post-load lock-state probe (read-only)"
for k in 1 2 3; do
  timeout 15 "$FB" getvar max-download-size >"$OUT/gv.txt" 2>&1
  cat "$OUT/gv.txt"
  grep -q 'max-download-size' "$OUT/gv.txt" && break
done
timeout 25 "$FB" oem device info </dev/null >"$OUT/devinfo.txt" 2>&1
tr -d '\r\000' < "$OUT/devinfo.txt"
timeout 25 "$FB" oem get-build-number </dev/null >"$OUT/buildno.txt" 2>&1
tr -d '\r\000' < "$OUT/buildno.txt"
if grep -q 'UNLOCKED' "$OUT/devinfo.txt"; then
  echo "[+] WRITABLE CHANNEL CONFIRMED (FB LockState UNLOCKED)"
else
  echo "[!] channel is not UNLOCKED -- do not flash"
fi
echo "[=] baseline partition-name resolution (read-only)"
python tools/fbraw.py --cmd "getvar storage:kernel" --cmd "getvar storage:system" \
    --cmd "getvar storage:boot" --outdir "$OUT/raw_ptn" --seconds 8 2>&1 \
  | grep -E '^---|head:|verdict='
echo "[*] end $(date +%H:%M:%S) log=$OUT"