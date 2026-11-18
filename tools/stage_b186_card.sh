#!/bin/bash
# 把"本机自己的官方 B186 dload"摆到卡上（唯一 verlist 接受当前版本、且能重写分区表的官方动作）。
# 卡上原有的 B379 那份不删，改名留下；两张新文件写完必须整张回读 sha256 与源比对，才算摆好。
set -u
cd "C:/Users/64563/Desktop/maimang6" || exit 2
CARDW="F:/"          # 给 bash 用
CARDP='F:\'          # 给 PowerShell 用
SRC="fw_b186/Software/dload"
OUT="out_check/stage_b186_$(date +%H%M%S)"; mkdir -p "$OUT"; exec >> >(tee "$OUT/run.log") 2>&1
echo "[*] start $(date +%H:%M:%S)"

lsrun() { powershell -NoProfile -Command "$1" 2>&1 | sed 's/^/    /'; }
echo "[=] 卡当前内容"
lsrun "Get-ChildItem -Force -LiteralPath '$CARDP' | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize"
lsrun "Get-ChildItem -Force -Recurse -LiteralPath '${CARDP}dload' -ErrorAction SilentlyContinue | Select-Object FullName,Length | Format-Table -AutoSize"

if [ -d "${CARDW}dload" ]; then
  mv "${CARDW}dload" "${CARDW}dload_b379_kept" && echo "[=] 原 dload 已改名为 dload_b379_kept（一个字节都没删）"
fi
mkdir -p "${CARDW}dload/RNE-AL00_all_cn" || { echo "[x] 建目录失败,卡不可写?"; exit 3; }

copy_one() {  # 源 目标 期望大小
  local s="$1" d="$2" want="$3" got src_sum dst_sum dsz
  got=$(stat -c %s "$s" 2>/dev/null || echo 0)
  if [ "$got" != "$want" ]; then echo "[x] 源大小不符 $s ($got != $want),中止"; exit 4; fi
  src_sum=$(sha256sum "$s" | cut -d' ' -f1)
  echo "[=] $(date +%H:%M:%S) 复制 $(basename "$s") $want B  src-sha=${src_sum:0:16}…"
  cp "$s" "$d" || { echo "[x] 复制失败"; exit 5; }
  dsz=$(stat -c %s "$d" 2>/dev/null || echo 0)
  if [ "$dsz" != "$want" ]; then echo "[x] 目标大小不符 ($dsz != $want)"; exit 6; fi
  echo "    $(date +%H:%M:%S) 整张回读 sha256 …"
  dst_sum=$(sha256sum "$d" | cut -d' ' -f1)
  if [ "$dst_sum" != "$src_sum" ]; then echo "[x] 回读不一致! src=$src_sum dst=$dst_sum"; exit 7; fi
  echo "[+] $(basename "$d") 逐字节一致 sha=$dst_sum ($(date +%H:%M:%S))"
}

copy_one "$SRC/UPDATE.APP" "${CARDW}dload/UPDATE.APP" 4165383612
copy_one "$SRC/RNE-AL00_all_cn/update_RNE-AL00_all_cn.app" "${CARDW}dload/RNE-AL00_all_cn/update_RNE-AL00_all_cn.app" 2006599848

echo "[=] 卡上最终结构"
lsrun "Get-ChildItem -Force -Recurse -LiteralPath '${CARDP}dload' | Select-Object FullName,Length | Format-Table -AutoSize"
lsrun "\$v=Get-Volume -DriveLetter F; 'free={0:N0} fst={1}' -f \$v.SizeRemaining,\$v.FileSystem"
echo "[*] end $(date +%H:%M:%S) log=$OUT"