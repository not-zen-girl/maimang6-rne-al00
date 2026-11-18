#!/bin/bash
# One-line device verdict. DOWNLOAD (PID_3609) is terminal: xloader is back in its loop,
# which means the boot attempt already ended — no point waiting for adb any longer.
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
A="./platform-tools/adb.exe -L tcp:5039"
ids=$(powershell -NoProfile -Command "((Get-PnpDevice -PresentOnly | Where-Object { \$_.InstanceId -like '*VID_12D1*' -or \$_.InstanceId -like '*VID_18D1*' } | ForEach-Object { \$_.InstanceId }) -join ' ')" 2>/dev/null | tr -d '\r')
adb=$($A devices 2>/dev/null | grep -cw device); fb=$($FB devices 2>/dev/null | grep -c fastboot)
case "$ids" in
  *PID_3609*) v="DOWNLOAD(xloader 下载循环 = 本次尝试已终止)";;
  *PID_D00D*) v="FASTBOOT/LK";;
  *PID_108A*|*PID_107E*|*PID_1106*) v="枚举到别的口(可能是已开机/HiSuite)";;
  *) v="USB 上无设备(关机/充电/内核在跑)";;
esac
echo "$(date +%H:%M:%S) verdict=$v adb_rows=$adb fastboot_rows=$fb"
echo "$ids" | tr ' ' '\n' | grep -E "VID_(12D1|18D1)" | head -6
