#!/usr/bin/env bash
# 定向修复 vrl 的 fastboot 证书槽(0x6000),把 EMUI-8 B379 的证书换回本机原装 B186 的。
#
# ⚠ vrl 本来在禁写集里。本脚本是 2026-11-17 17:1x 用户明确批准("写")的一次性例外。
#   依据(全部已证):
#   - xloader 0x224 读 vrl 偏移 0x6000 长度 0x1000,校验失败 return -1 → 不启动(bootfail 0xa2/0xa3)
#   - 0x5dc0 只校验传入的那一个块,无整分区校验和
#   - rollback_b186/fastboot.img[4096:] == rb186/fastboot.img 逐字节相同 ⇒ 证书对得上闪存字节
#   - 改动 289 B / 262144,范围 0x674c..0x687d,其余一字节不动
#   - LK write_vrl(0x1d9720)门槛实测 *(u32*)0x30693d00 == 0 ⇒ 合法刷新路径已死,只能手工换块
#
# 只写 vrl 一个分区。不写 vrl_backup(xloader 先读 vrl,过了就不看 backup)。
# 不写 ptable/efuse/oeminfo/frp/nvme/modem*/secure_storage/userdata。
# 拿不到 Writing OKAY 就停。**本脚本不 reboot** —— 先做零写入读回校验,由用户决定重启。
set -u
cd "$(dirname "$0")/.." || exit 1
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
OUT="out_check/fixvrl_$(date +%H%M%S)"; mkdir -p "$OUT"
exec >> >(tee "$OUT/run.log") 2>&1

IMG="fix_vrl/vrl_b186cert.img"
RST="fix_vrl/vrl_original.img"
WSHA="41be06b9dd46ac4f41993cb856d88e9624ac8ba80ff0854d9d0c0feb0ff6b025"
RSHA="4988f47970d124ecf4ef032a9f6b379b2aa73627a4cc3b90e56c8d04a863115c"

echo "[*] start $(date +%H:%M:%S)  定向修复 vrl@0x6000 证书槽(只写 vrl,不 reboot)"

gate() { # name path wantsize wantsha
  local n="$1" p="$2" wsz="$3" wsha="$4" sz got
  if [ ! -f "$p" ]; then echo "  gate| BAD $n 文件不存在 $p"; return 1; fi
  sz=$(wc -c < "$p" | tr -d ' ')
  got=$(sha256sum "$p" | cut -d' ' -f1)
  echo "  gate| $n $p size=$sz (期望 $wsz)"
  echo "  gate|   sha=$got"
  if [ "$sz" != "$wsz" ] || [ "$got" != "$wsha" ]; then
    echo "  gate| BAD $n 校验不过"; return 1
  fi
  echo "  gate| OK  $n"; return 0
}

gate vrl_fixed "$IMG" 262144 "$WSHA" || { echo "[x] 校验门没过,不写"; exit 3; }
# 还原镜像必须同时在手且完好,否则这次写入不可逆 —— 宁可不写
gate vrl_restore "$RST" 262144 "$RSHA" || { echo "[x] 还原镜像缺失/损坏,不可逆,不写"; exit 3; }
echo "[+] 校验门通过(写入镜像 + 还原镜像都在手)"

if ! $FB devices 2>/dev/null | grep -q fastboot; then
  echo "[x] 现在没有 fastboot 通道 —— 先跑 tools/pair_split.sh b186p,不写"; exit 4
fi
echo "[=] 通道在:$($FB devices 2>&1 | tr '\n' ' ')"

# 只读预检:17:28 那次 flash 空输出 = exe 卡在写入前的 getvar 上被 timeout 120 杀掉(121s)。
# 先用一条只读 getvar 探通道并吸收可能的丢首包;答不出期望值就不写。
echo "[=] 只读预检 max-download-size:"
pre=$(timeout 15 $FB getvar max-download-size 2>&1 | tr -d '\r\000')
echo "$pre" | sed 's/^/    /'
if ! echo "$pre" | grep -q "max-download-size: 471859200"; then
  echo "[x] 预检没答出 471859200 —— 通道卡死,不写(零改动)"; exit 7
fi
echo "[+] 预检通过,通道活着"

echo "[w] $(date +%H:%M:%S) flash vrl  ($IMG)"
o=$(timeout 120 $FB flash vrl "$IMG" 2>&1); echo "$o" | sed 's/^/    /'
if [ -z "$(echo "$o" | tr -d '[:space:]')" ]; then
  echo "[x] flash 返回空输出 —— exe 卡住被 timeout 杀掉,零改动,不 reboot"; exit 6
fi
if echo "$o" | grep -qi "not allowed"; then
  echo "[x] vrl 被拒(Command not allowed)—— 零改动,停"; exit 5
fi
if ! echo "$o" | grep -q "Writing 'vrl'.*OKAY"; then
  echo "[x] 没拿到 Writing 'vrl' OKAY —— 停在这里,不 reboot"; exit 6
fi
if echo "$o" | grep -q "Writing 'vrl'.*OKAY \[  0.000s\]"; then
  echo "[!] Writing 耗时 0.000s —— 疑似只 ACK 未落盘,必须靠读回校验判定"
fi

echo "[=] $(date +%H:%M:%S) 拿到 Writing OKAY。**不 reboot**,下一步零写入读回校验:"
echo "    python tools/fbraw.py --outdir $OUT --cmd 'getvar storage:vrl' --cmd 'upload_storage:86000:1000'"
echo "    (addr 是绝对字节地址:vrl 起始 0x80000 + 槽内偏移 0x6000 = 0x86000)"
echo "    判据:读回 4096 B == rollback_b186/fastboot.img[:4096] 才算落盘;== emui8_b379 那张就是没写进去"
echo "[*] end $(date +%H:%M:%S) log=$OUT"