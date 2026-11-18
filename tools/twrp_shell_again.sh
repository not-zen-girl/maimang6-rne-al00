#!/bin/bash
# Put the 5.1 TWRP pair back into kernel/ramdisk (the only path that ever gave a shell),
# reset the boot-state flags so the LK really tries, then race for that shell. Read-only after.
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
A="./platform-tools/adb.exe -L tcp:5039"
PS="powershell -ExecutionPolicy Bypass -File rescue/deepflash/deepflash.ps1 -Port COM3"
XL="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_xloader.img"
LK="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_fastboot.img"
G='/dev/block/platform/*/*.*/by-name'
OUT="out_check/shell2_$(date +%H%M%S)"; mkdir -p "$OUT"; exec >> >(tee "$OUT/run.log") 2>&1
echo "[*] start $(date +%H:%M:%S)"

load() { $PS -Plan "0x00020000=$XL;0x10000000=$LK" 2>&1 | tail -1 | sed 's/^/  load| /'; }
grab() {
  timeout 60 $A wait-for-device
  for pair in "cat /proc/cmdline:cmdline.txt" "ls -l $G:byname.txt" "blockdev --getsize64 /dev/block/mmcblk0:disksize.txt" \
              "cat /proc/device-tree/model:dtmodel.txt" "mount:mounts.txt" "ls /dev/block/platform:plat.txt"; do
    cmd="${pair%:*}"; f="${pair##*:}"; timeout 40 $A exec-out "sh -c '$cmd'" > "$OUT/$f" 2>&1
    echo "    read $f = $(wc -c < "$OUT/$f") B"
  done
  timeout 90 $A exec-out "sh -c 'dd if=/dev/block/mmcblk0 bs=1048576 count=1 2>/dev/null'" > "$OUT/gpt_head_1MiB.bin" 2>"$OUT/gpt.err"
  echo "    read gpt_head_1MiB.bin = $(wc -c < "$OUT/gpt_head_1MiB.bin") B"
  SZ=$(grep -o -E "[0-9]{9,}" "$OUT/disksize.txt" | head -1)
  [ -n "$SZ" ] && timeout 60 $A exec-out "sh -c 'dd if=/dev/block/mmcblk0 bs=1024 count=64 skip=$((SZ-65536)) iflag=skip_bytes 2>/dev/null'" > "$OUT/gpt_tail_64KiB.bin" 2>&1
  for n in vrl vrl_backup ptable boot kernel misc bootfail_info; do
    timeout 40 $A exec-out "sh -c 'dd if=$G/$n bs=1024 count=64 2>/dev/null'" > "$OUT/${n}.head.bin" 2>"$OUT/${n}.err"
    echo "    read $n = $(wc -c < "$OUT/${n}.head.bin") B $(head -c 40 "$OUT/${n}.err" | tr -d '\r')"
  done
  timeout 40 $A exec-out "sh -c 'id; uptime; getprop ro.product.model; ls /dev/block/bootdevice/by-name 2>/dev/null | head -3'" > "$OUT/id.txt" 2>&1
  echo "[+] capture complete in $OUT"
}

if ! $FB devices 2>/dev/null | grep -q fastboot; then echo "[*] RAM-loading LK"; load; fi
$FB devices 2>/dev/null | grep -q fastboot || { echo "[!] no fastboot"; exit 3; }

for pair in "kernel:rb379/twrp_kernel_for_kernel.img:46624268b283591ebe6275458636fc94997741d67c4a094d63b8045f437e67d9" \
            "ramdisk:rb379/twrp_ramdisk_for_ramdisk.img:53c8d22f6746f8711451818699b41d0f8b09a2bc0aad168648b11ee3c92094e6"; do
  name="${pair%%:*}"; rest="${pair#*:}"; f="${rest%%:*}"; want="${rest##*:}"
  got=$(sha256sum "$f" | cut -d' ' -f1)
  if [ "$want" != "$got" ]; then echo "[!] $name sha256 mismatch want=$want got=$got"; exit 5; fi
  echo "[=] $name sha256 OK ($(stat -c %s "$f") B) $(date +%H:%M:%S)"
  $FB flash "$name" "$f" 2>&1 | tail -2 | sed "s/^/    $name| /"
done
for n in misc bootfail_info; do echo "[=] erase $n"; $FB erase "$n" 2>&1 | tail -1 | sed "s/^/    $n| /"; done

for n in 1 2 3; do
  echo "===== attempt $n $(date +%H:%M:%S)"
  $FB reboot 2>&1 | tail -1 | sed 's/^/  reboot| /'
  for i in $(seq 1 30); do
    st=$($A get-state 2>&1 | tr -d '\r')
    [ $((i % 10)) -eq 0 ] && echo "  t+$((i*5))s adb=[$st]"
    if [ "$st" = "device" ]; then echo "[+] SHELL UP $(date +%H:%M:%S)"; sleep 8; grab; echo "[*] end $(date +%H:%M:%S)"; exit 0; fi
    sleep 5
  done
  echo "  [!] no shell, reloading LK from RAM and retrying"
  load
done
echo "[!] no shell obtained"; echo "[*] end $(date +%H:%M:%S) log=$OUT"