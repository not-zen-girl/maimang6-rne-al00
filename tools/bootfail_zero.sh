#!/bin/bash
# One variable: replace the 0xFF boot-failure record my `erase` created with an all-zero one,
# then boot the pair that actually worked at 17:0x. Corrected probe: no verdict inside 60 s,
# and the download port only counts as terminal when seen twice, 10 s apart.
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
A="./platform-tools/adb.exe -L tcp:5039"
PS="powershell -ExecutionPolicy Bypass -File rescue/deepflash/deepflash.ps1 -Port COM3"
XL="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_xloader.img"
LK="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_fastboot.img"
OUT="out_check/bootfail_zero_$(date +%H%M%S)"; mkdir -p "$OUT"; exec >> >(tee "$OUT/run.log") 2>&1
echo "[*] start $(date +%H:%M:%S)"
Z="$OUT/zero_2MiB.bin"; [ -f "$Z" ] || dd if=/dev/zero of="$Z" bs=1048576 count=2 status=none
echo "[=] payload: $(stat -c %s "$Z") bytes, unique bytes = $(tr -d '\0' < "$Z" | wc -c) non-zero"
ids_now() { powershell -NoProfile -Command "((Get-PnpDevice -PresentOnly | Where-Object { \$_.InstanceId -like '*VID_12D1*' -or \$_.InstanceId -like '*VID_18D1*' } | ForEach-Object { \$_.InstanceId }) -join ' ')" 2>/dev/null | tr -d '\r'; }
load() { $PS -Plan "0x00020000=$XL;0x10000000=$LK" 2>&1 | tail -1 | sed 's/^/  load| /'; }

$FB devices 2>/dev/null | grep -q fastboot || load
$FB devices 2>/dev/null | grep -q fastboot || { echo "[!] no fastboot"; exit 3; }
echo "[=] flash bootfail_info (2 MiB zeros) $(date +%H:%M:%S)"
$FB flash bootfail_info "$Z" 2>&1 | tail -2 | sed 's/^/    flash| /'

for n in 1 2 3; do
  $FB devices 2>/dev/null | grep -q fastboot || load
  echo "===== attempt $n $(date +%H:%M:%S) → 正常启动 (kernel/ramdisk = 17:0x 成功过的那对)"
  $FB reboot 2>&1 | tail -1 | sed 's/^/  reboot| /'
  dl=0
  for i in $(seq 1 24); do
    sleep 10
    adb=$($A devices 2>/dev/null | grep -cw device)
    if [ "$adb" != "0" ]; then echo "[+] ADB UP at t+$((i*10))s $(date +%H:%M:%S)"; sleep 8; bash tools/capture_state.sh; echo "[*] end $(date +%H:%M:%S)"; exit 0; fi
    if [ "$i" -ge 6 ]; then
      case "$(ids_now)" in
        *PID_3609*) dl=$((dl+1)); echo "  t+$((i*10))s 下载口在场(连续 $dl 次)"; [ "$dl" -ge 2 ] && { echo "  → 判定终止"; break; };;
        *) dl=0; echo "  t+$((i*10))s 无下载口,仍在启动中";;
      esac
    else
      echo "  t+$((i*10))s (宽限期内,不下结论)"
    fi
  done
done
echo "[!] no shell obtained"; echo "[*] end $(date +%H:%M:%S) log=$OUT"