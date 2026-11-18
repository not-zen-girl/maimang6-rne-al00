#!/bin/bash
# 只修一件事：把带 4096 签名头的 LK 换成去头那份，让偏移 0 处重新是代码。
# 19:38 那次把 emui8_b379/fastboot.img（带头）写进了 fastboot 分区，之后所有测量都作废。
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
A="./platform-tools/adb.exe -L tcp:5039"
PS="powershell -ExecutionPolicy Bypass -File rescue/deepflash/deepflash.ps1 -Port COM3"
XL="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_xloader.img"
LK="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_fastboot.img"
IMG="dd_set/fastboot.img"; WANT="d0dce6e2178c861ddeab9f7e527c6d543e5ca7d30578d63b85aae8f90eed00b0"; SZ=2864640
OUT="out_check/fix_lk_$(date +%H%M%S)"; mkdir -p "$OUT"; exec >> >(tee "$OUT/run.log") 2>&1
echo "[*] start $(date +%H:%M:%S)"
ids_now() { powershell -NoProfile -Command "((Get-PnpDevice -PresentOnly | Where-Object { \$_.InstanceId -like '*VID_12D1*' -or \$_.InstanceId -like '*VID_18D1*' } | ForEach-Object { \$_.InstanceId }) -join ' ')" 2>/dev/null | tr -d '\r' | sed 's/USB.//g'; }
load() { $PS -Plan "0x00020000=$XL;0x10000000=$LK" 2>&1 | tail -1 | sed 's/^/  load| /'; }
up() { $FB devices 2>/dev/null | grep -q fastboot; }

got=$(sha256sum "$IMG" | cut -d' ' -f1); sz=$(stat -c %s "$IMG")
echo "[=] payload $IMG $sz B sha=${got:0:16}…"
[ "$sz" = "$SZ" ] || { echo "[x] 大小不符,不动闪存"; exit 4; }
[ "$got" = "$WANT" ] || { echo "[x] 哈希不符,不动闪存"; exit 4; }
head16=$(head -c 4 "$IMG" | xxd -p); echo "[=] 偏移 0 前 4 字节 = $head16 (期望 0d000014 = ARM64 跳转表)"

up || load
up || { echo "[!] 没有 fastboot 通道"; exit 3; }
echo "[=] $(date +%H:%M:%S) flash fastboot"
out=$($FB flash fastboot "$IMG" 2>&1); echo "$out" | tail -3 | sed 's/^/    /'
echo "$out" | grep -qiE 'FAIL|not exist|error' && { echo "[x] 写入被拒,中止"; exit 6; }

echo "[+] 写完。下面这次 reboot 第一次跑的是盘里刚放的 LK(代码在偏移 0)"
$FB reboot 2>&1 | tail -1 | sed 's/^/  reboot| /'
dl=0
for i in $(seq 1 30); do
  sleep 10
  adb=$($A devices 2>/dev/null | grep -cw device)
  if [ "$adb" != "0" ]; then echo "[+] ADB 上线 t+$((i*10))s $(date +%H:%M:%S)"; sleep 8; bash tools/capture_state.sh; echo "[*] end $(date +%H:%M:%S)"; exit 0; fi
  ids=$(ids_now)
  if [ "$i" -ge 6 ]; then
    case "$ids" in
      *PID_3609*) dl=$((dl+1)); echo "  t+$((i*10))s 下载口(连续 $dl 次)"; [ "$dl" -ge 2 ] && { echo "  → 判定终止"; break; };;
      *PID_D00D*) dl=0; echo "  t+$((i*10))s fastboot 在答话(盘里的 LK 起来了)";;
      "") dl=0; echo "  t+$((i*10))s 手机完全不在总线上";;
      *) dl=0; echo "  t+$((i*10))s 是另一种枚举: $ids";;
    esac
  else
    echo "  t+$((i*10))s 宽限期内不下结论; 当前枚举=${ids:-无}"
  fi
done
echo "[!] 没有 shell"; echo "[*] end $(date +%H:%M:%S) log=$OUT"