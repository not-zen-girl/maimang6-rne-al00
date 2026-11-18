#!/bin/bash
# The TWRP kernel boots but dies after minutes, so automate: load LK -> reboot -> race for a
# shell -> grab the partition table read-back first. Bounded number of attempts.
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
A="./platform-tools/adb.exe -L tcp:5039"
PS="powershell -ExecutionPolicy Bypass -File rescue/deepflash/deepflash.ps1 -Port COM3"
XL="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_xloader.img"
LK="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_fastboot.img"
OUT="out_check/gpt_readback"; mkdir -p "$OUT"
ATTEMPTS=${1:-3}

grab() { # highest value first: what the kernel parsed from the GPT, then the raw bytes
  timeout 40 $A exec-out "sh -c 'ls -l /dev/block/platform/*/*.*/by-name'" > "$OUT/byname.txt" 2>&1
  echo "  byname bytes=$(wc -c < "$OUT/byname.txt")"
  timeout 30 $A exec-out "sh -c 'blockdev --getsize64 /dev/block/mmcblk0'" > "$OUT/disksize.txt" 2>&1
  timeout 60 $A exec-out "sh -c 'dd if=/dev/block/mmcblk0 bs=1048576 count=1 2>/dev/null'" > "$OUT/head_1MiB.bin" 2>"$OUT/head_1MiB.err"
  echo "  head bytes=$(wc -c < "$OUT/head_1MiB.bin")"
  SZ=$(grep -o -E "[0-9]{9,}" "$OUT/disksize.txt" | head -1)
  if [ -n "$SZ" ]; then
    timeout 60 $A exec-out "sh -c 'dd if=/dev/block/mmcblk0 bs=1024 count=64 skip=$((SZ-65536)) iflag=skip_bytes 2>/dev/null'" > "$OUT/tail_64KiB.bin" 2>&1
    echo "  tail bytes=$(wc -c < "$OUT/tail_64KiB.bin") size=$SZ"
  fi
  timeout 40 $A exec-out "sh -c 'for n in ptable boot kernel ramdisk recovery version; do echo \"## \$n\"; dd if=/dev/block/platform/*/*.*/by-name/$n bs=512 count=1 2>/dev/null | hexdump -C | head -3; done'" > "$OUT/peeks.txt" 2>&1
  timeout 40 $A exec-out "sh -c 'id; getprop ro.product.device; uptime'" > "$OUT/id.txt" 2>&1
}

for n in $(seq 1 "$ATTEMPTS"); do
  echo "===== attempt $n at $(date +%H:%M:%S)"
  $PS -Plan "0x00020000=$XL;0x10000000=$LK" 2>&1 | tail -2 | sed 's/^/  load| /'
  if ! $FB devices 2>/dev/null | grep -q .; then echo "  [!] no fastboot after load, waiting 20s"; sleep 20; fi
  $FB reboot 2>&1 | tail -1 | sed 's/^/  reboot| /'
  ok=0
  for i in $(seq 1 70); do
    st=$($A get-state 2>&1 | tr -d '\r')
    if [ "$st" = "device" ]; then ok=1; break; fi
    # bail out early if the phone gave up and is sitting in the download port again
    if [ $((i % 10)) -eq 0 ]; then
      com=$(powershell -NoProfile -Command "[string]::Join(',',([System.IO.Ports.SerialPort]::GetPortNames()))")
      echo "  t+$((i*3))s state=$st com=[$com]"
    fi
    sleep 3
  done
  if [ "$ok" = "1" ]; then
    echo "  shell up at $(date +%H:%M:%S), grabbing"
    sleep 5
    grab
    echo "  ===== got it, stopping"; break
  fi
  echo "  [!] attempt $n: no shell"
done
ls -l "$OUT"; echo "[*] end at $(date +%H:%M:%S)"