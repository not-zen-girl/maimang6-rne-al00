#!/bin/bash
# Interpret port flaps: pnputil asks the PnP manager live, so it separates
# "Windows power-managed the COM interface" from "the device actually left the bus".
prev=""
while :; do
  com=$(powershell -NoProfile -Command "[string]::Join(',',([System.IO.Ports.SerialPort]::GetPortNames()))" 2>/dev/null)
  xloader=$(pnputil /enum-devices /connected 2>/dev/null | grep -A3 -i 'VID_12D1&PID_3609' | grep -ci 'Connected' )
  other=$(powershell -NoProfile -Command "((Get-PnpDevice -PresentOnly | Where-Object { \$_.InstanceId -match 'VID_12D1' -and \$_.InstanceId -notmatch '2MM0223B14022394' } | ForEach-Object { if (\$_.InstanceId -match 'VID_[0-9A-F]{4}&PID_[0-9A-F]{4}') { \$Matches[0] } }) | Sort-Object -Unique) -join '+'" 2>/dev/null)
  state="COM=[$com] XL3609_CONNECTED=$xloader USB=[$other]"
  if [ "$state" != "$prev" ]; then
    echo "$(date +%H:%M:%S) $state"
    prev="$state"
  fi
  sleep 0.5
done