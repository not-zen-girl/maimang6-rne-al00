#!/bin/bash
# 零写入探测:LK 接受哪些 reboot 入口?接受的那条就是官方升级器的门。
# 每条都记录设备原样回复 + 之后 20 秒的 USB 实例号变化,不接受就下一条。
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
PS="powershell -ExecutionPolicy Bypass -File rescue/deepflash/deepflash.ps1 -Port COM3"
XL="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_xloader.img"
LK="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_fastboot.img"
OUT="out_check/entries_$(date +%H%M%S)"; mkdir -p "$OUT"; exec >> >(tee "$OUT/run.log") 2>&1
echo "[*] start $(date +%H:%M:%S)  (本脚本不写闪存)"
ids_now() { powershell -NoProfile -Command "((Get-PnpDevice -PresentOnly | Where-Object { \$_.InstanceId -like '*VID_12D1*' -or \$_.InstanceId -like '*VID_18D1*' } | ForEach-Object { \$_.InstanceId }) -join ' ')" 2>/dev/null | tr -d '\r' | sed 's/USB.//g'; }
load() { $PS -Plan "0x00020000=$XL;0x10000000=$LK" 2>&1 | tail -1 | sed 's/^/  load| /'; }
up() { $FB devices 2>/dev/null | grep -q fastboot; }

for w in normal sdcard sdpatch sdupdate rescue erecovery recovery; do
  [ "$w" = "normal" ] && cmd="reboot" || cmd="reboot $w"
  up || load
  if ! up; then echo "===== $w : 拿不到 fastboot,跳过"; continue; fi
  echo "===== $w  $(date +%H:%M:%S)"
  out=$($FB $cmd 2>&1); echo "$out" | tail -3 | sed 's/^/    /'
  for i in 1 2 3; do
    sleep 10
    case "$(ids_now)" in
      *PID_3609*) echo "    t+$((i*10))s 下载口";;
      *PID_D00D*) echo "    t+$((i*10))s fastboot(回到 LK 等命令)";;
      "") echo "    t+$((i*10))s 手机不在总线上(没有下载口=它没在走失败即回退的那条路)";;
      *) echo "    t+$((i*10))s 其它枚举: $(ids_now)";;
    esac
  done
done
echo "[*] end $(date +%H:%M:%S) log=$OUT"