#!/bin/bash
# After a reboot, only report identity transitions: xloader download port vs an LK in fastboot mode.
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
prev=""
for i in $(seq 1 30); do
  sig=$(powershell -NoProfile -Command '$t=@(); foreach($d in (Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match "VID_12D1&PID_3609|VID_18D1" })){ if($d.InstanceId -match "PID_3609"){ $t+="XL3609" } else { $t+="FB_D00D" } }; ($t | Sort-Object -Unique) -join "+"') 2>/dev/null
  n=$( { $FB devices 2>/dev/null | grep -c .; } )
  a=$(./platform-tools/adb.exe devices 2>/dev/null | tail -n +2 | grep -c .)
  cur="usb=[$sig] fastboot_rows=$n adb_rows=$a"
  if [ "$cur" != "$prev" ]; then
    echo "$(date +%H:%M:%S) $cur"
    prev="$cur"
  fi
  sleep 3
done
echo "$(date +%H:%M:%S) window end (90s)"