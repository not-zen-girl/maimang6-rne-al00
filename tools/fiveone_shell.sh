#!/bin/bash
# Reproduce the ONLY configuration that ever booted, with its original dependency restored:
# 5.1 board DT (dts) + 5.1-generation TWRP kernel/ramdisk. Then capture everything read-only.
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
A="./platform-tools/adb.exe -L tcp:5039"
PS="powershell -ExecutionPolicy Bypass -File rescue/deepflash/deepflash.ps1 -Port COM3"
XL="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_xloader.img"
LK="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_fastboot.img"
OUT="out_check/fiveone_shell_$(date +%H%M%S)"; mkdir -p "$OUT"; exec >> >(tee "$OUT/run.log") 2>&1
echo "[*] start $(date +%H:%M:%S)"

dts_ok=$(node -e 'const m=require("./rb186/manifest.json");const r=m.find(x=>x.name==="dts");console.log(r.sha256)')
sha_of(){ sha256sum "$1" | cut -d' ' -f1; }
declare -A W=( [dts]="rb186/dts.img:$dts_ok" \
  [kernel]="rb379/twrp_kernel_for_kernel.img:46624268b283591ebe6275458636fc94997741d67c4a094d63b8045f437e67d9" \
  [ramdisk]="rb379/twrp_ramdisk_for_ramdisk.img:53c8d22f6746f8711451818699b41d0f8b09a2bc0aad168648b11ee3c92094e6" )

$FB devices 2>/dev/null | grep -q fastboot || $PS -Plan "0x00020000=$XL;0x10000000=$LK" 2>&1 | tail -1 | sed 's/^/  load| /'
$FB devices 2>/dev/null | grep -q fastboot || { echo "[!] no fastboot"; exit 3; }
for name in dts kernel ramdisk; do
  spec=${W[$name]}; f="${spec%%:*}"; want="${spec##*:}"; got=$(sha_of "$f")
  if [ "$want" != "$got" ]; then echo "[!] $name sha256 MISMATCH want=$want got=$got — stopping"; exit 5; fi
  echo "[=] $name sha256 OK ($(stat -c %s "$f") B) $(date +%H:%M:%S)"
  $FB flash "$name" "$f" 2>&1 | tail -2 | sed "s/^/    $name| /"
done
for n in 1 2; do
  echo "[*] reboot #$n $(date +%H:%M:%S) — 屏幕若出现 TWRP 界面请告诉我"
  $FB reboot 2>&1 | tail -1 | sed 's/^/  reboot| /'
  for i in $(seq 1 30); do
    st=$($A get-state 2>&1 | tr -d '\r')
    [ $((i % 12)) -eq 0 ] && echo "  t+$((i*5))s adb=[$st]"
    if [ "$st" = "device" ]; then echo "[+] SHELL UP $(date +%H:%M:%S)"; sleep 8; bash tools/capture_state.sh; echo "[*] end $(date +%H:%M:%S)"; exit 0; fi
    sleep 5
  done
  echo "  [!] no shell; RAM-loading LK again"
  $PS -Plan "0x00020000=$XL;0x10000000=$LK" 2>&1 | tail -1 | sed 's/^/  load| /'
done
echo "[!] no shell obtained"; echo "[*] end $(date +%H:%M:%S) log=$OUT"