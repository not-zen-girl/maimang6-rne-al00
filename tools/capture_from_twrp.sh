#!/bin/bash
# Reboot, wait for a shell, then capture everything worth reading in one go (the earlier
# session died after a few minutes, so nothing may be asked one-command-at-a-time).
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
A="./platform-tools/adb.exe -L tcp:5039"
OUT="out_check/twrp2"; mkdir -p "$OUT"
PLAT="soc_hi6250_pcie"
BN=$(ls -d /dev 2>/dev/null; echo)   # placeholder, real path is discovered on device

echo "[*] rebooting"
$FB reboot 2>&1 | tail -2

echo "[*] waiting up to 200s for an adb device"
timeout 200 $A wait-for-device 2>&1 | tail -1
# "shell true" prints an error line when nothing is there, so match the real state instead.
ok=0
for i in $(seq 1 40); do
  if [ "$($A get-state 2>&1 | tr -d '\r')" = "device" ]; then ok=1; break; fi
  sleep 3
done
if [ "$ok" != "1" ]; then
  echo "[!] no usable adb device. fastboot view:"
  $FB devices 2>&1
  exit 3
fi
sleep 8

ex() { # ex <file> <device shell command>   retries once if the device dropped out
  echo "--- $1 : $2"
  timeout 60 $A exec-out "sh -c '$2'" > "$OUT/$1" 2>"$OUT/$1.err"
  if [ ! -s "$OUT/$1" ]; then
    echo "    empty (err: $(head -c 60 "$OUT/$1.err" | tr -d '\r')), waiting 20s for the device and retrying once"
    sleep 20
    timeout 60 $A exec-out "sh -c '$2'" > "$OUT/$1" 2>"$OUT/$1.err"
  fi
  echo "    bytes=$(wc -c < "$OUT/$1")"
}

ex 00_id.txt          "id; getprop ro.product.device; getprop ro.build.version.release; uptime; df /data | tail -2"
ex 01_byname.txt      "ls -l /dev/block/platform/*/*.*/by-name 2>/dev/null; ls -l /dev/block/by-name 2>/dev/null"
ex 02_disksize.txt    "blockdev --getsize64 /dev/block/mmcblk0; blockdev --getsz /dev/block/mmcblk0"
ex 03_head_1MiB.bin   "dd if=/dev/block/mmcblk0 bs=1048576 count=1 2>/dev/null"
ex 04_byname_names.txt "ls /dev/block/by-name 2>/dev/null | sort; echo ====; ls /dev/block/platform/*/*.*/by-name 2>/dev/null | sed s.*/by-name/.. | sort"
ex 05_peek_kernel.txt "X=/dev/block/platform/*/*.*/by-name; for n in kernel ramdisk boot recovery recovery2 version ptable bootfail_info; do echo \"## \$n\"; dd if=\$X/\$n bs=512 count=1 2>/dev/null | hexdump -C | head -3; done"
ex 06_mounts.txt      "mount | head -30; echo ====; ls -l /sys/block/mmcblk0/device/size 2>/dev/null; cat /sys/block/mmcblk0/device/size 2>/dev/null; getprop | grep -i -e boot -e fail | head -20"

SZ=$(grep -o -E "^[0-9]{9,}" "$OUT/02_disksize.txt" | head -1)
if [ -n "$SZ" ]; then
  OFF=$((SZ - 65536))
  echo "[*] tail of the disk at byte $OFF (backup GPT lives here)"
  ex 07_tail_64KiB.bin "dd if=/dev/block/mmcblk0 bs=1024 count=64 skip=$OFF iflag=skip_bytes 2>/dev/null"
else
  echo "[!] disk size not captured, skipping the tail read"
fi
echo "[*] done. files in $OUT"
ls -l "$OUT"