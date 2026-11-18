#!/system/bin/sh
# keep_adb.sh — EMUI8 拔线自动关 USB 调试的持久化对策
# 安装位置: /data/adb/service.d/keep_adb.sh (Magisk late_start 开机自启, root)
# 策略:
#   1. 开机完成后先开启一次 adb;
#   2. 监听 USB 插入(开始充电)沿: /sys/class/power_supply/USB/online 0->1,
#      插入后等 5s 让 EMUI 完成 USB 重配/自动关闭, 再重新开启 adb;
#   3. 兜底: 插着线但 adb_enabled 被关成 0 也重新开启;
#   4. usb_conn_prompt=0 去掉每次重连的 RSA 授权弹窗(PC 密钥已在 adb_keys)。
# 可逆: 删除本脚本即恢复 EMUI 原行为。不动 /system, 不动稳定组件。

LOG=/data/adb/keep_adb.log
USBON=/sys/class/power_supply/USB/online

enable_adb() {
  settings put global adb_enabled 1
  settings put global allow_charging_adb 1
  settings put secure usb_conn_prompt 0
}

# 等开机完成
while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
sleep 5
enable_adb
echo "$(date '+%m-%d %H:%M:%S') boot: adb enabled" >> "$LOG"

prev=$(cat "$USBON" 2>/dev/null); [ -z "$prev" ] && prev=0
while true; do
  cur=$(cat "$USBON" 2>/dev/null); [ -z "$cur" ] && cur=0
  if [ "$cur" = "1" ] && [ "$prev" != "1" ]; then
    # 开始充电沿: 等 5s 让系统稳定再开
    sleep 5
    enable_adb
    echo "$(date '+%m-%d %H:%M:%S') charge-start: adb re-enabled" >> "$LOG"
  elif [ "$cur" = "1" ] && [ "$(settings get global adb_enabled)" != "1" ]; then
    enable_adb
    echo "$(date '+%m-%d %H:%M:%S') fallback: adb re-enabled" >> "$LOG"
  fi
  prev=$cur
  sleep 2
done