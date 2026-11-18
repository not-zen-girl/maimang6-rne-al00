#!/bin/bash
# 补上唯一缺的一环:把盘里 5.1 的 xloader 换成官方 EMUI-8 的(带 4096 签名前缀)。
# 通道:00:12 用带前缀官方对从 COM1.0 拉起来的官方 LK,下载模式,max-download-size=471859200,
# 与 IDT 成功深刷日志 PASS_2018-09-30_14.15.35.log 的握手值一致。
# 只写 xloader。不碰 efuse/oeminfo/frp/nvme/modem_*/secure_storage/userdata。
# 回滚:rollback_b186/xloader.img (69184 B, sha 27652e36…)
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
IMG="emui8_b379/xloader.img"
WANT="104a27db2a03627d6548a4fa98d609dae2fc7f2203fced8e05fae59a5da31a39"
OUT="out_check/xloader8_$(date +%H%M%S)"; mkdir -p "$OUT"; exec >> >(tee "$OUT/run.log") 2>&1
echo "[*] start $(date +%H:%M:%S)  一条写入:flash xloader(官方 EMUI-8,带前缀)"

sz=$(wc -c < "$IMG"); got=$(sha256sum "$IMG" | cut -d' ' -f1)
echo "  gate| $IMG  size=$sz (期望 69568)  sha=$got"
if [ "$sz" != "69568" ] || [ "$got" != "$WANT" ]; then echo "[x] 校验门没过,不写"; exit 3; fi
echo "  gate| 前 16 字节 = $(head -c 16 "$IMG" | xxd -p) (期望 00000000000000000100000001000000)"
echo "[+] 校验门通过"

up()  { $FB devices 2>/dev/null | grep -q fastboot; }
ids() { powershell -NoProfile -ExecutionPolicy Bypass -File tools/phone_ids.ps1 2>/dev/null | tr -d '\r' | tr '\n' ' '; }
if ! up; then echo "[x] 现在没有 fastboot。先跑 tools/pair_split.sh emu8p"; exit 4; fi
echo "[=] 通道在:$($FB devices 2>&1 | head -1)"

echo "[w] $(date +%H:%M:%S) flash xloader"
o=$($FB flash xloader "$IMG" 2>&1)
echo "$o" | sed 's/^/    /'
if echo "$o" | grep -qi "not allowed\|FAILED\|error"; then
  echo "[x] 这个模式不许写 xloader —— 没有任何改动,停"
  echo "[*] end $(date +%H:%M:%S) log=$OUT"; exit 5
fi
if ! echo "$o" | grep -q "Writing 'xloader'.*OKAY"; then
  echo "[x] 没拿到 Writing OKAY,不 reboot,停在这里"
  echo "[*] end $(date +%H:%M:%S) log=$OUT"; exit 6
fi
echo "[+] Writing OKAY —— 注意上面的耗时:非 0.000s 才说明是真写"

echo "[=] $(date +%H:%M:%S) reboot —— 请看屏幕:华为 logo / 开机动画 / 任何字"
$FB reboot 2>&1 | tail -1 | sed 's/^/    /'

echo "[=] 观察 180 秒(前 60 秒不下结论)"
for i in $(seq 1 18); do
  sleep 10
  s=$(ids)
  case "$s" in
    *PID_3609*) tag="下载口 COM1.0(没越过 xloader)";;
    *PID_D00D*) tag="fastboot(盘里 LK 起来了)";;
    "")         tag="不在总线上";;
    *)          tag="另一种枚举(可能是系统侧)";;
  esac
  if [ $((i*10)) -le 60 ]; then pre="宽限期内不下结论; "; else pre=""; fi
  echo "  t+$((i*10))s ${pre}${tag}: ${s:-（无）}"
done
echo "[*] end $(date +%H:%M:%S) log=$OUT"