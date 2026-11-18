#!/bin/bash
# Watch only for changes: which COM ports exist, and which Huawei USB identities are present.
prev_com=""
prev_usb=""
while :; do
  com=$(powershell -NoProfile -Command "[string]::Join(',',([System.IO.Ports.SerialPort]::GetPortNames()))" 2>/dev/null)
  usb=$(powershell -NoProfile -Command "((Get-PnpDevice -PresentOnly | Where-Object { \$_.InstanceId -match 'VID_12D1' -and \$_.InstanceId -notmatch '2MM0223B14022394' } | ForEach-Object { if (\$_.InstanceId -match 'VID_[0-9A-F]{4}&PID_[0-9A-F]{4}') { \$Matches[0] } }) | Sort-Object -Unique) -join '+'" 2>/dev/null)
  if [ "$com" != "$prev_com" ]; then
    echo "$(date +%H:%M:%S) COM=[$com]"
    prev_com="$com"
  fi
  if [ "$usb" != "$prev_usb" ]; then
    echo "$(date +%H:%M:%S) USB=[$usb]"
    prev_usb="$usb"
  fi
  sleep 0.5
done