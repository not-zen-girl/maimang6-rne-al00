#!/usr/bin/env bash
# Roll back to the verified EMUI 5.1 C00B186 set after the EMUI 8 experiment.
# Order mirrors the upgrade: partition table first (the 5.1 names boot/recovery only exist again
# after that), re-enumerate fastboot, then the official B186 images.  All from fw_b186/... UPDATE.APP
# (curver RNE-AL00C00B186, sha256 of UPDATE.APP recorded in stock_b186/SHA256SUMS.txt).
set -uo pipefail
cd "$(dirname "$0")"
FB=./platform-tools/fastboot.exe
LOG=rollback_log.txt
R=rollback_b186

[ "${1:-}" = "--go" ] || { echo "需要显式加 --go 才会真正写入"; exit 1; }
sha256sum -c <(echo "e3741c8ae4915882a39dc83ad11705e42b4161b2352638a327f40e1218deb423  backups/gpt_b186_filled.img") || exit 1
for p in xloader fw_lpm3 teeos trustfirmware sensorhub modemnvm_update modem_fw dts \
         recovery recovery2 cache system vendor product fastboot; do
  [ -s "$R/$p.img" ] || { echo "缺少 $R/$p.img"; exit 1; }
done
[ -s stock_b186/boot_pure.img ] || { echo "缺少 stock_b186/boot_pure.img"; exit 1; }

step() {
  echo "+ fastboot $*"
  echo "[$(date '+%H:%M:%S')] fastboot $*" >>"$LOG"
  if "$FB" "$@" >>"$LOG" 2>&1; then
    grep -E "OKAY|FAILED|Error|finished|Erasing" "$LOG" | tail -2 | sed 's/^/    /'
  else
    tail -6 "$LOG" | sed 's/^/    /'
    echo "!! 失败停在这里，见 $LOG"
    exit 1
  fi
}

[ "$("$FB" devices 2>/dev/null | grep -c .)" -ge 1 ] || { echo "看不到 fastboot 设备"; exit 1; }

echo "== 回滚 1/3 写回 5.1 分区表 =="
step flash efi backups/gpt_b186_filled.img
"$FB" reboot bootloader >>"$LOG" 2>&1
sleep 8
for i in $(seq 1 90); do
  [ "$("$FB" devices 2>/dev/null | grep -c .)" -ge 1 ] && break
  sleep 2
done
[ "$("$FB" devices 2>/dev/null | grep -c .)" -ge 1 ] || { echo "!! 等 fastboot 超时"; exit 1; }

echo "== 回滚 2/3 写回 B186 镜像 =="
for p in xloader fw_lpm3 teeos trustfirmware sensorhub modemnvm_update modem_fw dts recovery recovery2 cache system vendor product; do
  step flash "$p" "$R/$p.img"
done
step flash boot stock_b186/boot_pure.img
step flash fastboot "$R/fastboot.img"
step erase misc
"$FB" erase userdata >>"$LOG" 2>&1 && echo "+ fastboot erase userdata   OK"

echo "== 回滚 3/3 重启 =="
"$FB" reboot >>"$LOG" 2>&1
echo "已重启回 EMUI 5.1（首次开机要重建数据分区，会慢）"