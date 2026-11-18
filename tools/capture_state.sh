#!/bin/bash
# Read-only evidence capture from whatever booted (recovery/TWRP/system). Auto-detects by-name.
cd "C:/Users/64563/Desktop/maimang6" || exit 2
A="./platform-tools/adb.exe -L tcp:5039"
OUT="out_check/state_$(date +%H%M%S)"; mkdir -p "$OUT"; exec >> >(tee "$OUT/run.log") 2>&1
echo "[*] start $(date +%H:%M:%S)"; timeout 60 $A wait-for-device
$A root >/dev/null 2>&1; sleep 2; timeout 30 $A wait-for-device
BN=$($A shell "for d in /dev/block/platform/*/*.*/by-name /dev/block/bootdevice/by-name /dev/disk/by-partlabel; do [ -d \"\$d\" ] && echo \"\$d\"; done" 2>/dev/null | tr -d '\r' | head -1)
echo "[*] by-name dir = ${BN:-none found}"
run(){ f="$1"; shift; timeout 45 $A exec-out "sh -c '$*'" > "$OUT/$f" 2>&1; echo "  $f = $(wc -c < "$OUT/$f") B"; }
run cmdline.txt   "cat /proc/cmdline"
run dtmodel.txt   "cat /proc/device-tree/model 2>/dev/null; cat /proc/device-tree/compatible 2>/dev/null | tr '\\0' ' '"
run uname.txt     "uname -a; id; uptime; getprop ro.product.model; getprop ro.build.display.id; getprop ro.recovery.ui 2>/dev/null"
run byname.txt    "ls -l $BN"
run disksize.txt  "blockdev --getsize64 /dev/block/mmcblk0"
run mounts.txt    "mount | sed -n '1,60p'"
run dts_present.txt "ls -l $BN"
timeout 90 $A exec-out "sh -c 'dd if=/dev/block/mmcblk0 bs=1048576 count=1 2>/dev/null'" > "$OUT/gpt_head_1MiB.bin" 2>"$OUT/gpt_head.err"
echo "  gpt_head_1MiB.bin = $(wc -c < "$OUT/gpt_head_1MiB.bin") B"
SZ=$(grep -o -E "[0-9]{9,}" "$OUT/disksize.txt" | head -1)
if [ -n "$SZ" ]; then
  echo "[*] disk size = $SZ bytes"
  timeout 90 $A exec-out "sh -c 'dd if=/dev/block/mmcblk0 bs=1024 count=64 skip=$((SZ-65536)) iflag=skip_bytes 2>/dev/null'" > "$OUT/gpt_tail_64KiB.bin" 2>&1
  echo "  gpt_tail_64KiB.bin = $(wc -c < "$OUT/gpt_tail_64KiB.bin") B"
fi
for n in vrl vrl_backup ptable boot kernel ramdisk recovery_ramdisk misc bootfail_info dts; do
  timeout 40 $A exec-out "sh -c 'dd if=$BN/$n bs=1024 count=64 2>/dev/null'" > "$OUT/${n}.head.bin" 2>"$OUT/${n}.err"
  printf "  %-18s %8s B  %s\n" "$n" "$(wc -c < "$OUT/${n}.head.bin")" "$(head -c 50 "$OUT/${n}.err" | tr -d '\r\n')"
done
echo "[*] end $(date +%H:%M:%S) files in $OUT"