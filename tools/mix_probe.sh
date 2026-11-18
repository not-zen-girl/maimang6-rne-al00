#!/bin/bash
# 把"哪一张图触发拒绝"分开测：两段式会话(见 pair_split.sh 的注释),但两半各自可换。
# mixA = 工具 xloader + 官方 EMUI-8 LK   → 若 fastboot 起来,说明官方 LK 本身能跑,嫌疑只剩 5.1 xloader 那一侧
# mixB = 官方 EMUI-8 xloader + 工具 LK   → 若这张能过,说明拒绝只跟 LK 那张有关;若同样 07/掉线,说明是"载完官方 xloader 后方言变了"
# 全程不写闪存。
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
B='C:\Users\64563\Desktop\maimang6'
T_XL="$B\rescue\tools\hisi\hisi65x_b_xloader.img"; T_LK="$B\rescue\tools\hisi\hisi65x_b_fastboot.img"
E_XL="$B\rb379\xloader_pure.img";                  E_LK="$B\dd_set\fastboot.img"
case "$1" in
  mixA) XL="$T_XL"; LK="$E_LK"; WANT="官方 EMUI-8 的 LK 能不能被拉起来";;
  mixB) XL="$E_XL"; LK="$T_LK"; WANT="官方 xloader 之后工具 LK 还能不能传";;
  *) echo "用法: $0 mixA|mixB"; exit 2;;
esac
PSS() { powershell -ExecutionPolicy Bypass -File rescue/deepflash/deepflash.ps1 -Port COM3 -WatchSeconds 15 -Plan "$1" 2>&1 | iconv -f GBK -t UTF-8 2>/dev/null; }
OUT="out_check/${1}_$(date +%H%M%S)"; mkdir -p "$OUT"; exec >> >(tee "$OUT/run.log") 2>&1
echo "[*] start $(date +%H:%M:%S) $1 : xloader=$(basename "$XL") + LK=$(basename "$LK")  判据:$WANT  (不写闪存)"
for f in "$XL" "$LK"; do p="${f//\\//}"; [ -f "$p" ] || { echo "[x] 文件不在:$p"; exit 3; }; done
up()  { $FB devices 2>/dev/null | grep -q fastboot; }
ids() { powershell -NoProfile -Command "((Get-PnpDevice -PresentOnly | Where-Object { \$_.InstanceId -like '*VID_12D1*' -or \$_.InstanceId -like '*VID_18D1*' } | ForEach-Object { \$_.InstanceId }) -join ' ')" 2>/dev/null | tr -d '\r' | sed 's/USB.//g'; }
say() { echo "$1" | grep -E "send |done |ACK|FAILED|RESULT|open " | sed "s/^/  load| /"; }
if up; then echo "[=] 现在在 fastboot,先送回下载口"; $FB reboot 2>&1 | tail -1 | sed 's/^/    /'; sleep 30; fi

echo "[1/2] $(date +%H:%M:%S) 只送 xloader"
say "$(PSS "0x00020000=$XL")"
for i in 1 2 3 4 5 6 7 8; do sleep 5; ids | grep -q PID_3609 && { echo "    下载口在(t+$((i*5))s)"; sleep 5; break; }; echo "    t+$((i*5))s 还没下载口"; done

echo "[2/2] $(date +%H:%M:%S) 只送 LK"
say "$(PSS "0x10000000=$LK")"
for i in 2 3 4 5 6 7 8 9 10 11 12; do
  sleep 10
  if up; then echo "[+] $1：LK 起来了,在答 fastboot  ← $WANT：能"; echo "    getvar product → $($FB getvar product 2>&1 | tr '\n' ' ' | cut -c1-120)"; echo "[*] end $(date +%H:%M:%S) log=$OUT"; exit 0; fi
  s=$(ids); case "$s" in *PID_3609*) echo "  t+$((i*10))s 下载口(连续 $((i-1)) 次)";; *) echo "  t+$((i*10))s 另一种枚举: $s";; esac
done
echo "[-] $1：没有 fastboot  ← $WANT：不能。当前枚举=$(ids)"
echo "[*] end $(date +%H:%M:%S) log=$OUT"