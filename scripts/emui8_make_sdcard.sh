#!/usr/bin/env bash
# Stage the official dload payload onto a microSD card for 三键强刷 (Huawei TPupgrade).
#   ./emui8_make_sdcard.sh /e            # /e = the card's mount point
#   ./emui8_make_sdcard.sh /e --verify   # also sha256 every copied file (slow on a cheap card)
# The card MUST be FAT32 and 8-32 GB is the safest choice: Windows formats 64 GB+ as exFAT and
# NTFS, which the TPupgrade loader cannot read.  Slot 2 is shared with SIM2, so power off first.
set -uo pipefail
cd "$(dirname "$0")"
D="${1:-}"
SRC=fw_b379/dload
[ -n "$D" ] && [ -d "$D" ] || { echo "用法: $0 /e  （存储卡挂载点）"; exit 1; }

free=$(df -P "$D" | awk 'NR==2{print $4}')
need=$(( (4055692392 + 2099177116 + 1024 * 1024 * 64) / 1024 ))
[ "${free:-0}" -gt "$need" ] || { echo "空间不足：需要 $((need / 1024 / 1024)) GB，可用 $((free / 1024 / 1024)) GB"; exit 1; }

echo "!! 前提：这张卡必须是 FAT32。现在检查有没有 NTFS/exFAT 的痕迹（有就说明格式不对，先格式化）"
if [ -e "$D/\$MFT" ] || [ -e "$D/System Volume Information" ]; then
  echo "!! 检测到 NTFS/exFAT 痕迹，请先在 Windows 里把卡格式化成 FAT32 再运行本脚本。"
  exit 1
fi

mkdir -p "$D/dload/RNE-AL00_all_cn" || exit 1
echo "== 复制 dload/UPDATE.APP (4,055,692,392 B) =="
cp "$SRC/UPDATE.APP" "$D/dload/UPDATE.APP" || exit 1
echo "== 复制 dload/RNE-AL00_all_cn/update_RNE-AL00_all_cn.app (2,099,177,116 B) =="
cp "$SRC/RNE-AL00_all_cn/update_RNE-AL00_all_cn.app" "$D/dload/RNE-AL00_all_cn/" || exit 1

echo "== 字节数核对 =="
fail=0
check() {
  local want=$1 file=$2 got
  got=$(stat -c %s "$file" 2>/dev/null || echo 0)
  if [ "$got" = "$want" ]; then echo "  OK   $file  $got"; else echo "  大小不符 $file  $got != $want"; fail=1; fi
}
check 4055692392 "$D/dload/UPDATE.APP"
check 2099177116 "$D/dload/RNE-AL00_all_cn/update_RNE-AL00_all_cn.app"
[ $fail -eq 0 ] || { echo "复制不完整，重新格式化卡片再来一次。"; exit 1; }

if [ "${2:-}" = "--verify" ]; then
  echo "== sha256 全量校验（慢，取决于卡速）=="
  (cd "$D/dload" && sha256sum UPDATE.APP RNE-AL00_all_cn/update_RNE-AL00_all_cn.app)
  echo "源文件应为 UPDATE.APP = 4cdcd393a9f6cf2cbd4da48f65f3a6991f558193fa2b1acf40e66289852d269e"
fi

echo
echo "就绪。三键强刷步骤："
echo "  1) 手机关机，把卡插入卡槽2（与 SIM2 共用）"
echo "  2) 同时长按 音量上 + 音量下 + 电源，直到出现升级画面再松手"
echo "  3) 它会自动格式化数据并升级；全程别拔线别断电，第一次开机很慢"
echo "  注意：三键强刷拒绝同版本和低版本，我们是 5.1→8.0 属于升版本；它一定清数据。"