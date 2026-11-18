#!/usr/bin/env bash
# Step 1 of the EMUI 8.0.0.379 upgrade: zero-net-change channel probe.
# 1) put the verified stock B186 boot back (fuse: no Magisk-patched kernel live during the upgrade)
# 2) write the phone's CURRENT partition table back over itself byte-for-byte, to prove Huawei's
#    fastboot allows ptable writes at all.  Nothing changes if both succeed.
set -uo pipefail
cd "$(dirname "$0")"
FB=./platform-tools/fastboot.exe
LOG=flash_log.txt
[ -f stock_b186/boot_pure.img ] || { echo "缺少 stock_b186/boot_pure.img"; exit 1; }
sha256sum -c <(echo "e3741c8ae4915882a39dc83ad11705e42b4161b2352638a327f40e1218deb423  backups/gpt_primary_current.img") || exit 1

n=$("$FB" devices 2>/dev/null | grep -c "FASTBOOT\|fastboot\|68U5T18328012368" || true)
[ "${n:-0}" -ge 1 ] || { echo "看不到 fastboot 设备：先让手机进 fastboot（电源+音量下+音量上 或 adb reboot bootloader）"; exit 1; }
echo "fastboot 设备: $("$FB" devices 2>/dev/null | head -1)"

step() {
  echo
  echo "+ fastboot $*"
  echo "[$(date '+%H:%M:%S')] fastboot $*" >>"$LOG"
  if "$FB" "$@" >>"$LOG" 2>&1; then
    tail -3 "$LOG" | sed 's/^/    /'
  else
    tail -5 "$LOG" | sed 's/^/    /'
    echo "!! 这一步失败，脚本停在这里；后续分区没有被写过。"
    exit 1
  fi
  sleep 1
}

echo "== 保险丝：恢复官方 stock boot（当前是 Magisk 修补过的）=="
step flash boot stock_b186/boot_pure.img

echo "== 零改动探针：把本机现在的分区表原样回写（字节完全相同）=="
step flash efi backups/gpt_primary_current.img

echo
echo "两步都通过 → 华为 fastboot 允许写 ptable，可以进入 step2。"