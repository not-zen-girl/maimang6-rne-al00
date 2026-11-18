#!/bin/bash
# Single-variable test: put the EMUI-8 LK into partition `fastboot` (same LBA in both tables).
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
A="./platform-tools/adb.exe -L tcp:5039"
PS="powershell -ExecutionPolicy Bypass -File rescue/deepflash/deepflash.ps1 -Port COM3"
XL="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_xloader.img"
LK="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_fastboot.img"
IMG="emui8_b379/fastboot.img"
LOG="logs/lk_swap_$(date +%H%M%S).log"
mkdir -p logs; exec >> >(tee -a "$LOG") 2>&1
echo "[*] start $(date +%H:%M:%S)  image=$IMG sha256=$(sha256sum "$IMG" | cut -c1-16)"

if ! $FB devices 2>/dev/null | grep -q fastboot; then
  echo "[*] no fastboot, RAM-loading LK"
  $PS -Plan "0x00020000=$XL;0x10000000=$LK" 2>&1 | tail -2 | sed 's/^/  load| /'
fi
if ! $FB devices 2>/dev/null | grep -q fastboot; then echo "[!] still no fastboot, stopping"; exit 3; fi

echo "[*] flashing $IMG"
$FB flash fastboot "$IMG" 2>&1 | tail -3 | sed 's/^/  flash| /'
echo "[*] reboot at $(date +%H:%M:%S) — screen is the primary instrument now"
$FB reboot 2>&1 | tail -1 | sed 's/^/  reboot| /'
for i in $(seq 1 40); do
  fb=$($FB devices 2>/dev/null | grep -c fastboot)
  st=$($A get-state 2>&1 | tr -d '\r')
  com=$(powershell -NoProfile -Command "[string]::Join(',',([System.IO.Ports.SerialPort]::GetPortNames()))")
  echo "  t+$((i*5))s fastboot_rows=$fb adb=[$st] com=[$com]"
  [ "$st" = "device" ] && { echo "[+] adb shell is UP"; break; }
  sleep 5
done
echo "[*] end $(date +%H:%M:%S)  log=$LOG"