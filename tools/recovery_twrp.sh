#!/bin/bash
# Recovery-mode boot of the only pair ever proven to run on this board: 5.1 TWRP kernel + TWRP ramdisk.
# Uses the download-port verdict as a stop signal so a dead attempt costs seconds, not minutes.
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
A="./platform-tools/adb.exe -L tcp:5039"
PS="powershell -ExecutionPolicy Bypass -File rescue/deepflash/deepflash.ps1 -Port COM3"
XL="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_xloader.img"
LK="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_fastboot.img"
F="rb379/twrp_ramdisk_for_ramdisk.img"; WANT=53c8d22f6746f8711451818699b41d0f8b09a2bc0aad168648b11ee3c92094e6
OUT="out_check/recovery_twrp_$(date +%H%M%S)"; mkdir -p "$OUT"; exec >> >(tee "$OUT/run.log") 2>&1
echo "[*] start $(date +%H:%M:%S)"

verdict() { powershell -NoProfile -Command "((Get-PnpDevice -PresentOnly | Where-Object { \$_.InstanceId -like '*VID_12D1*' -or \$_.InstanceId -like '*VID_18D1*' } | ForEach-Object { \$_.InstanceId }) -join ' ')" 2>/dev/null | tr -d '\r'; }
load() { $PS -Plan "0x00020000=$XL;0x10000000=$LK" 2>&1 | tail -1 | sed 's/^/  load| /'; }

got=$(sha256sum "$F" | cut -d' ' -f1)
[ "$WANT" = "$got" ] || { echo "[!] sha256 MISMATCH want=$WANT got=$got"; exit 5; }
$FB devices 2>/dev/null | grep -q fastboot || load
$FB devices 2>/dev/null | grep -q fastboot || { echo "[!] no fastboot"; exit 3; }
echo "[=] recovery_ramdisk sha256 OK ($(stat -c %s "$F") B) $(date +%H:%M:%S)"
$FB flash recovery_ramdisk "$F" 2>&1 | tail -2 | sed 's/^/    flash| /'

for n in 1 2 3; do
  $FB devices 2>/dev/null | grep -q fastboot || load
  echo "===== attempt $n $(date +%H:%M:%S) → reboot recovery"
  $FB reboot recovery 2>&1 | tail -1 | sed 's/^/  reboot| /'
  for i in $(seq 1 24); do
    sleep 10
    adb=$($A devices 2>/dev/null | grep -cw device)
    [ "$adb" != "0" ] && { echo "[+] ADB UP at t+$((i*10))s $(date +%H:%M:%S)"; sleep 8; bash tools/capture_state.sh; echo "[*] end $(date +%H:%M:%S)"; exit 0; }
    ids=$(verdict)
    case "$ids" in
      *PID_3609*) echo "  t+$((i*10))s → 下载口出现,本次尝试已终止,不再等待"; break;;
      *) echo "  t+$((i*10))s 仍在启动中 (ids: $(echo "$ids" | tr ' ' ',' | cut -c1-70))";;
    esac
  done
done
echo "[!] no shell obtained"; echo "[*] end $(date +%H:%M:%S) log=$OUT"