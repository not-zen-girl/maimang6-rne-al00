#!/bin/bash
# Restore the 5.1 LK (user's ask), observe whether the phone self-answers fastboot again,
# then race for the TWRP shell that already sits in kernel/ramdisk. Read-only afterwards.
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
A="./platform-tools/adb.exe -L tcp:5039"
PS="powershell -ExecutionPolicy Bypass -File rescue/deepflash/deepflash.ps1 -Port COM3"
XL="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_xloader.img"
LK="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_fastboot.img"
IMG="rb186/fastboot.img"; G='/dev/block/platform/*/*.*/by-name'
OUT="out_check/restore51_$(date +%H%M%S)"; mkdir -p "$OUT"; exec >> >(tee "$OUT/run.log") 2>&1

want=$(node -e 'const m=require("./rb186/manifest.json");console.log(m.find(r=>r.name==="fastboot").sha256)')
got=$(sha256sum "$IMG" | cut -d" " -f1)
echo "[*] gate: want=$want"; echo "        got =$got"
[ "$want" = "$got" ] || { echo "[!] sha256 MISMATCH, refusing to flash"; exit 5; }

if ! $FB devices 2>/dev/null | grep -q fastboot; then
  echo "[*] RAM-loading LK $(date +%H:%M:%S)"; $PS -Plan "0x00020000=$XL;0x10000000=$LK" 2>&1 | tail -1 | sed 's/^/  load| /'
fi
$FB devices 2>/dev/null | grep -q fastboot || { echo "[!] no fastboot"; exit 3; }
echo "[*] writing $IMG"; $FB flash fastboot "$IMG" 2>&1 | tail -2 | sed 's/^/  flash| /'

grab() {
  timeout 40 $A wait-for-device
  for what in "cat /proc/cmdline:cmdline.txt" "ls -l $G:byname.txt" \
    "blockdev --getsize64 /dev/block/mmcblk0:disksize.txt"; do
    cmd="${what%:*}"; f="${what##*:}"; timeout 40 $A exec-out "sh -c '$cmd'" > "$OUT/$f" 2>&1; echo "  -> $f $(wc -c < "$OUT/$f") B"
  done
  timeout 60 $A exec-out "sh -c 'dd if=/dev/block/mmcblk0 bs=1048576 count=1 2>/dev/null'" > "$OUT/head_1MiB.bin" 2>"$OUT/head.err"
  echo "  -> head_1MiB.bin $(wc -c < "$OUT/head_1MiB.bin") B"
  for n in vrl boot ptable kernel; do
    timeout 30 $A exec-out "sh -c 'dd if=$G/$n bs=1024 count=48 2>/dev/null'" > "$OUT/${n}.head.bin" 2>"$OUT/${n}.err"
    echo "  -> $n $(wc -c < "$OUT/${n}.head.bin") B"
  done
  timeout 30 $A exec-out "sh -c 'id; uptime; getprop ro.product.model'" > "$OUT/id.txt" 2>&1
}

echo "[*] reboot to observe the restored flash LK by itself $(date +%H:%M:%S)"
$FB reboot 2>&1 | tail -1 | sed 's/^/  reboot| /'
for i in $(seq 1 18); do
  fb=$($FB devices 2>/dev/null | grep -c fastboot); st=$($A get-state 2>&1 | tr -d '\r')
  echo "  t+$((i*5))s self_fastboot=$fb adb=[$st]"
  if [ "$st" = "device" ]; then echo "[+] TWRP shell came up by itself"; sleep 5; grab; echo "[*] done $(date +%H:%M:%S)"; exit 0; fi
  if [ "$fb" != "0" ]; then echo "  [note] the flash LK is alive in fastboot mode (boot chain works, but nothing bootable)"; fi
  sleep 5
done
for n in 1 2 3; do
  echo "===== race attempt $n at $(date +%H:%M:%S) (RAM-load + reboot, no writes)"
  $PS -Plan "0x00020000=$XL;0x10000000=$LK" 2>&1 | tail -1 | sed 's/^/  load| /'
  $FB reboot 2>&1 | tail -1 | sed 's/^/  reboot| /'
  for i in $(seq 1 30); do
    st=$($A get-state 2>&1 | tr -d '\r')
    [ "$i" ] && [ $((i % 10)) -eq 0 ] && echo "  t+$((i*5))s adb=[$st]"
    if [ "$st" = "device" ]; then echo "[+] shell UP"; sleep 5; grab; echo "[*] done $(date +%H:%M:%S)"; exit 0; fi
    sleep 5
  done
  echo "  [!] attempt $n: no shell"
done
echo "[!] no shell obtained; log in $OUT"; echo "[*] end $(date +%H:%M:%S)"