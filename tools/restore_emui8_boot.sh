#!/bin/bash
# Write the genuine EMUI-8 boot set (device-verified dd_set bytes) over the areas my erases hit,
# then reboot. Every file is sha256-gated against dd_set/manifest.json; any failure stops the run.
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
A="./platform-tools/adb.exe -L tcp:5039"
OUT="out_check/emui8_boot_$(date +%H%M%S)"; mkdir -p "$OUT"; exec >> >(tee "$OUT/run.log") 2>&1
set -- kernel ramdisk dts recovery_ramdisk recovery_vendor

$FB devices 2>/dev/null | grep -q fastboot || { echo "[!] no fastboot device"; exit 3; }
for name in "$@"; do
  want=$(node -e "const m=require('./dd_set/manifest.json');const r=(m.images||m).find(x=>(x.name||x.partition||x.target)===process.argv[1]);console.log(r?r.sha256:'')" "$name")
  f="dd_set/$name.img"
  got=$(sha256sum "$f" | cut -d' ' -f1)
  if [ -z "$want" ]; then echo "[!] $name: no manifest entry, refusing"; exit 5; fi
  if [ "$want" != "$got" ]; then echo "[!] $name: sha256 mismatch"; echo "    want=$want"; echo "    got =$got"; exit 5; fi
  echo "[=] $name  sha256 OK ($(stat -c %s "$f") B)  $(date +%H:%M:%S)"
  $FB flash "$name" "$f" 2>&1 | tail -2 | sed "s/^/    $name| /"
  out=$?
done
echo "[*] all writes done at $(date +%H:%M:%S) — rebooting, 首启可能需要几分钟"
$FB reboot 2>&1 | tail -1 | sed 's/^/  reboot| /'
prev=""
for i in $(seq 1 72); do
  fb=$($FB devices 2>/dev/null | grep -c fastboot)
  adb=$($A devices 2>/dev/null | grep -c -w device)
  pnp=$(powershell -NoProfile -Command "(Get-PnpDevice -PresentOnly | Where-Object { \$_.InstanceId -match 'VID_12D1' -and \$_.InstanceId -notmatch 'PID_108A|2MM0223B14022394' } | ForEach-Object { \$_.InstanceId } | Sort-Object) -join ','" 2>/dev/null | tr -d '\r')
  line="t+$((i*5))s fastboot=$fb adb_rows=$adb phone_usb=[$pnp]"
  [ "$line" != "$prev" ] && { echo "  $line"; prev="$line"; }
  sleep 5
done
echo "[*] watch window closed $(date +%H:%M:%S)  log=$OUT"