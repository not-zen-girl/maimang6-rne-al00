#!/usr/bin/env bash
# Step 2 of the EMUI 8.0.0.379 upgrade: write the real thing.
#   ptable flip -> re-enumerate fastboot -> full official image set -> wipe userdata/misc -> new fastboot last
# Refuses to run without --go.  Never touches nvme / oeminfo / modemnvm_factory|backup|img|system /
# secure_storage / persist / frp / splash2 (they are not in the package and keep identical LBAs).
set -uo pipefail
cd "$(dirname "$0")"
FB=./platform-tools/fastboot.exe
LOG=flash_log.txt
I=emui8_b379

[ "${1:-}" = "--go" ] || { echo "需要显式加 --go 才会真正写入"; exit 1; }
sha256sum -c <(echo "9cbb0b5936d1e8702d8ed67b2e101306728c1d3d892e003ef34b915e4ee7f728  backups/efi_emui8_fixed.img") || exit 1
for f in "$I"/*.img; do [ -s "$f" ] || { echo "缺少 $f"; exit 1; }; done

wait_fb() {
  for i in $(seq 1 90); do
    [ "$("$FB" devices 2>/dev/null | grep -c .)" -ge 1 ] && { echo "    fastboot 回来了: $("$FB" devices | head -1)"; return 0; }
    sleep 2
  done
  echo "!! 等设备回到 fastboot 超时；请手动进 fastboot 后重新运行本脚本的剩余部分。"
  exit 1
}

step() {
  echo "+ fastboot $*"
  echo "[$(date '+%H:%M:%S')] fastboot $*" >>"$LOG"
  if "$FB" "$@" >>"$LOG" 2>&1; then
    grep -E "OKAY|FAILED|Error|finished|Erasing|Creating" "$LOG" | tail -2 | sed 's/^/    /'
  else
    tail -6 "$LOG" | sed 's/^/    /'
    echo "!! 失败停在这里。此刻已写入的分区见 $LOG。回滚：./emui8_rollback_b186.sh --go"
    exit 1
  fi
}

n=$("$FB" devices 2>/dev/null | grep -c . || true)
[ "${n:-0}" -ge 1 ] || { echo "看不到 fastboot 设备"; exit 1; }

echo "== 1/6 写入 EMUI 8 分区表（唯一不可逆风险点，已逐字节验证过算法；回滚表在同目录）=="
step flash efi backups/efi_emui8_fixed.img
echo "   重启回 fastboot 让新表生效"
"$FB" reboot bootloader >>"$LOG" 2>&1
sleep 8
wait_fb

echo "== 2/6 新表可用性探针（cache 只有 6 MB，名字解析成功就说明新表能用）=="
step flash cache "$I/cache.img"

echo "== 3/6 引导链与安全区 =="
for p in xloader fw_lpm3 teeos trustfirmware sensorhub fw_hifi; do step flash "$p" "$I/$p.img"; done

echo "== 4/6 modem（modemnvm_update 已获同意）=="
for p in modemnvm_update modem_fw; do step flash "$p" "$I/$p.img"; done

echo "== 5/6 AVB / recovery / erecovery / 内核 / 系统分区 =="
for p in vbmeta recovery_vbmeta erecovery_vbmeta recovery_ramdisk recovery_vendor \
         erecovery_kernel erecovery_ramdisk erecovery_vendor dts kernel ramdisk \
         system vendor product odm cust preas preavs version; do
  step flash "$p" "$I/$p.img"
done

echo "== 6/6 清数据 + 最后写 fastboot 分区 =="
step erase misc
if "$FB" erase userdata >>"$LOG" 2>&1; then
  echo "+ fastboot erase userdata   OK"
else
  echo "!! erase userdata 失败 —— 先停下来人工判断（不要盲目重试）"
  exit 1
fi
step flash fastboot "$I/fastboot.img"

echo
echo "全部写入完成，重启。第一次开机会慢（正在建立数据分区），耐心等待开机画面走完。"
"$FB" reboot >>"$LOG" 2>&1
echo "[$(date '+%H:%M:%S')] reboot issued" >>"$LOG"