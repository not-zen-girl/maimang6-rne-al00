#!/bin/bash
# 官方 IDT 的时序本身就是一张图一次会话：Downloading xloader → Write delay=3000ms → re-enter download mode → 下一张。
# 一个 -Plan 塞两张图时，手机在 xloader 尾帧后就松手了：22:32 表现为 15 秒 Write 超时，22:46 表现为 8 毫秒掉线。
# 这里按它的规矩分开送：会话1 只送 xloader → 等下载口重新出现 → 会话2 只送 LK → 看有没有 fastboot。
# 全程不写闪存。
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
B='C:\Users\64563\Desktop\maimang6'
PSS() { powershell -ExecutionPolicy Bypass -File rescue/deepflash/deepflash.ps1 -Port COM3 -WatchSeconds 15 -Plan "$1" 2>&1 | iconv -f GBK -t UTF-8 2>/dev/null; }
case "$1" in
  emu8) XL="$B\rb379\xloader_pure.img";  LK="$B\dd_set\fastboot.img";;
  # 带 4096 签名前缀的官方对。剥前缀的 xloader 送进去帧全 ACK 但 BootROM 不执行,
  # 设备仍停在 BootROM 下载口,于是 2.8MB@0x10000000 的头帧被 NAK 0x07(22:53 与 00:06 两次复现)。
  emu8p) XL="$B\emui8_b379\xloader.img"; LK="$B\emui8_b379\fastboot.img";;
  b186) XL="$B\rb186\xloader.img";       LK="$B\rb186\fastboot.img";;
  # 带前缀的 5.1 官方对。EMUI-8 的 LK 把 5.1 时代的解锁标志读成"锁着"(只放开 max-download-size,
  # flash/getvar 全回 Command not allowed),所以换 5.1 官方 LK 来拿写盘权限。
  b186p) XL="$B\rollback_b186\xloader.img"; LK="$B\rollback_b186\fastboot.img";;
  tool) XL="$B\rescue\tools\hisi\hisi65x_b_xloader.img"; LK="$B\rescue\tools\hisi\hisi65x_b_fastboot.img";;
  toola) XL="$B\rescue\tools\hisi\hisi65x_a_xloader.img"; LK="$B\rescue\tools\hisi\hisi65x_a_fastboot.img";;
  *) echo "用法: $0 emu8|emu8p|b186|tool|toola"; exit 2;;
esac
OUT="out_check/pair_split_$1_$(date +%H%M%S)"; mkdir -p "$OUT"; exec >> >(tee "$OUT/run.log") 2>&1
echo "[*] start $(date +%H:%M:%S)  两段式送对:$1  xloader=$(basename "$XL") LK=$(basename "$LK")  (不写闪存)"
for f in "$XL" "$LK"; do p="${f//\\//}"; [ -f "$p" ] || { echo "[x] 文件不在:$p"; exit 3; }; done
up()  { $FB devices 2>/dev/null | grep -q fastboot; }
ids() { powershell -NoProfile -Command "((Get-PnpDevice -PresentOnly | Where-Object { \$_.InstanceId -like '*VID_12D1*' -or \$_.InstanceId -like '*VID_18D1*' } | ForEach-Object { \$_.InstanceId }) -join ' ')" 2>/dev/null | tr -d '\r' | sed 's/USB.//g'; }
say() { echo "$1" | grep -E "send |done |ACK|FAILED|RESULT|watch|open " | sed "s/^/  load| /"; }
if up; then echo "[=] 现在在 fastboot,先送回下载口"; $FB reboot 2>&1 | tail -1 | sed 's/^/    /'; sleep 30; fi

echo "[1/2] $(date +%H:%M:%S) 只送 xloader"
say "$(PSS "0x00020000=$XL")"
echo "[=] 等手机重新进下载模式(官方这里是 3 秒 + 重开口)"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  sleep 5
  if ids | grep -q PID_3609; then echo "    下载口在(t+$((i*5))s)  枚举=$(ids)"; sleep 5; break; fi
  if up; then echo "    t+$((i*5))s 直接出现 fastboot(只送 xloader 就起了?)"; break; fi
  echo "    t+$((i*5))s 还没下载口: $(ids)"
done

echo "[2/2] $(date +%H:%M:%S) 只送 LK"
say "$(PSS "0x10000000=$LK")"
echo "[=] 观察 120 秒(前 60 秒不下结论)"
for i in 2 3 4 5 6 7 8 9 10 11 12; do
  sleep 10
  if up; then echo "[+] $1 成对两段式：LK 起来了,在答 fastboot"; for v in version product hw-version; do echo "    getvar $v → $($FB getvar "$v" 2>&1 | tr '\n' ' ' | cut -c1-120)"; done; echo "[*] end $(date +%H:%M:%S) log=$OUT"; exit 0; fi
  s=$(ids); case "$s" in *PID_3609*) echo "  t+$((i*10))s 下载口(连续 $((i-1)) 次)";; *) echo "  t+$((i*10))s 另一种枚举: $s";; esac
done
echo "[-] $1：没有 fastboot。当前枚举=$(ids)"
echo "[*] end $(date +%H:%M:%S) log=$OUT"