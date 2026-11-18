#!/bin/bash
# 一次只往 RAM 里载"一对"，跑完就退出。不写闪存。
# 之所以拆开：22:32 那次 EMUI-8 对的第一帧就 Write 超时，把 COM3 卡在驱动里，
# 后面 5.1 对连续三次都是"端口被占"——那是通道坏了，不是配对结论。
# 通道一卡就只能靠人手重新拔插复位，所以这里不自动重试。
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
PS="powershell -ExecutionPolicy Bypass -File rescue/deepflash/deepflash.ps1 -Port COM3"
B='C:\Users\64563\Desktop\maimang6'
case "$1" in
  tool) XL="$B\rescue\tools\hisi\hisi65x_b_xloader.img";  LK="$B\rescue\tools\hisi\hisi65x_b_fastboot.img";;
  emu8) XL="$B\rb379\xloader_pure.img";  LK="$B\dd_set\fastboot.img";;
  b186) XL="$B\rb186\xloader.img";       LK="$B\rb186\fastboot.img";;
  *) echo "用法: $0 tool|emu8|b186  (tool=已知能起的那对,作对照)"; exit 2;;
esac
TAG="$1 xloader=$(basename "$XL") lk=$(basename "$LK")"
OUT="out_check/pair_one_$(basename $1)_$(date +%H%M%S)"; mkdir -p "$OUT"; exec >> >(tee "$OUT/run.log") 2>&1
echo "[*] start $(date +%H:%M:%S)  $TAG   (不写闪存)"
for f in "$XL" "$LK"; do
  p="${f//\\//}"
  [ -f "$p" ] || { echo "[x] 文件不在:$p"; exit 3; }
  echo "[=] 在:$p $(wc -c < "$p") B sha=$(sha256sum "$p" | cut -c1-16)…"
done

up() { $FB devices 2>/dev/null | grep -q fastboot; }
ids() { powershell -NoProfile -Command "((Get-PnpDevice -PresentOnly | Where-Object { \$_.InstanceId -like '*VID_12D1*' -or \$_.InstanceId -like '*VID_18D1*' } | ForEach-Object { \$_.InstanceId }) -join ' ')" 2>/dev/null | tr -d '\r' | sed 's/USB.//g'; }

# 纯读：只取这台 LK 的指纹(getvar 对它给的名字一律回桩值,所以名字图只能靠"写不接受")
asknames() {
  echo "  [读] 只查询,不写任何内容"
  for v in version product hw-version; do
    o=$($FB getvar "$v" 2>&1 | tr '\n' ' '); echo "    getvar $v → ${o:0:120}"
  done
}

# 上一对如果起来了会停在 fastboot，先把它送回下载口再载下一对
if up; then echo "[=] 现在在 fastboot,先 reboot 回下载口"; $FB reboot 2>&1 | tail -1 | sed 's/^/    /'; sleep 25; fi

echo "[=] $(date +%H:%M:%S) 载 RAM"
out=$($PS -Plan "0x00020000=$XL;0x10000000=$LK" 2>&1 | iconv -f GBK -t UTF-8 2>/dev/null)
echo "$out" | grep -E "send |done |ACK|FAILED|RESULT|watch|fastboot\.exe|open " | sed "s/^/  load| /"
if echo "$out" | grep -qE "超时|拒绝"; then
  echo "[!] 通道问题(超时或端口被占),没有任何配对结论。"
  echo "    下一步请人工复位:拔 USB → 等 10 秒 → 再插,然后重跑本脚本。"
  echo "[*] end $(date +%H:%M:%S) log=$OUT"; exit 4
fi
echo "[=] 观察 60 秒(前 60 秒不下结论)"
dl=0
for i in 2 3 4 5 6 7 8 9 10 11 12; do
  sleep 10; s=$(ids)
  case "$s" in
    *PID_D00D*) echo "  t+$((i*10))s fastboot 在答话";;
    *PID_3609*) dl=$((dl+1)); echo "  t+$((i*10))s 下载口(连续 $dl 次)";;
    *) echo "  t+$((i*10))s 另一种枚举: $s";;
  esac
  if up; then echo "[+] $TAG：LK 起来了"; asknames; echo "[*] end $(date +%H:%M:%S) log=$OUT"; exit 0; fi
done
echo "[-] $TAG：没有 fastboot。当前枚举=$(ids)"
echo "[*] end $(date +%H:%M:%S) log=$OUT"