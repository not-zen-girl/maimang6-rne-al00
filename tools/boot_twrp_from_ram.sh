#!/bin/bash
# Zero-write attempt: `fastboot boot <real image>` has never been tested with a real file.
# If the LK accepts it we get a shell without touching flash, and can read the live GPT directly.
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
A="./platform-tools/adb.exe -L tcp:5039"
PS="powershell -ExecutionPolicy Bypass -File rescue/deepflash/deepflash.ps1 -Port COM3"
XL="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_xloader.img"
LK="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_fastboot.img"
TWRP="twrp_rne_emui51.img"
OUT="out_check/ramboot_$(date +%H%M%S)"; mkdir -p "$OUT"
LOG="$OUT/run.log"; exec >> >(tee "$LOG") 2>&1

if ! $FB devices 2>/dev/null | grep -q fastboot; then
  echo "[*] RAM-loading LK $(date +%H:%M:%S)"
  $PS -Plan "0x00020000=$XL;0x10000000=$LK" 2>&1 | tail -2 | sed 's/^/  load| /'
fi
$FB devices 2>/dev/null | grep -q fastboot || { echo "[!] no fastboot, cannot try boot"; exit 3; }

echo "[*] fastboot boot $TWRP ($(stat -c %s "$TWRP") bytes) at $(date +%H:%M:%S)"
$FB boot "$TWRP" 2>&1 | sed 's/^/  boot| /'
up=0
for i in $(seq 1 25); do
  st=$($A get-state 2>&1 | tr -d '\r')
  if [ "$st" = "device" ]; then up=1; break; fi
  echo "  t+$((i*5))s adb=[$st]"
  sleep 5
done
if [ "$up" = "1" ]; then
  echo "[+] shell UP at $(date +%H:%M:%S) — grabbing, most valuable first"
  G='/dev/block/platform/*/*.*/by-name'
  timeout 40 $A wait-for-device
  timeout 40 $A exec-out "sh -c 'cat /proc/cmdline'"        > "$OUT/cmdline.txt" 2>&1
  timeout 40 $A exec-out "sh -c 'ls -l $G'"                 > "$OUT/byname.txt" 2>&1
  timeout 30 $A exec-out "sh -c 'blockdev --getsize64 /dev/block/mmcblk0'" > "$OUT/disksize.txt" 2>&1
  timeout 60 $A exec-out "sh -c 'dd if=/dev/block/mmcblk0 bs=1048576 count=1 2>/dev/null'" > "$OUT/head_1MiB.bin" 2>"$OUT/head.err"
  SZ=$(grep -o -E "[0-9]{9,}" "$OUT/disksize.txt" | head -1)
  [ -n "$SZ" ] && timeout 60 $A exec-out "sh -c 'dd if=/dev/block/mmcblk0 bs=1024 count=64 skip=$((SZ-65536)) iflag=skip_bytes 2>/dev/null'" > "$OUT/tail_64KiB.bin" 2>&1
  for n in vrl vrl_backup ptable boot kernel ramdisk; do
    timeout 30 $A exec-out "sh -c 'dd if=$G/$n bs=1024 count=48 2>/dev/null'" > "$OUT/${n}.head.bin" 2>"$OUT/${n}.err"
    echo "  $n -> $(wc -c < "$OUT/${n}.head.bin") bytes ($(head -c 60 "$OUT/${n}.err" | tr -d '\r'))"
  done
  timeout 30 $A exec-out "sh -c 'id; getprop ro.product.model; uptime; mount | grep -c block'" > "$OUT/id.txt" 2>&1
  echo "[+] done, files in $OUT"
else
  echo "[!] no shell after fastboot boot"
fi
echo "[*] end $(date +%H:%M:%S)"