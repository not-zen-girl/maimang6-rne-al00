#!/usr/bin/env bash
# 按 EMUI8 活分区表序重排 vrl 证书槽(根因:vrl 槽=活表序号×4096,EMUI8 重排了分区)。
# 把纠正镜像 vrl_emui8_layout.img 写进 vrl + vrl_backup。第 4 次 vrl 例外,用户已批「写两份」。
#
# 依据(全部离线逐字节证明,见 memory kirin-vrl-root-cause):
#   - LK 0xa6ddc 名字→分区序号(stride 0x40),GetVrlOffset(0x1285e0) 序号<<12;数组=[xloader,ptable]+GPT(GPT+2)
#   - B186 GPT 反验 8/8 吻合;EMUI8 fastboot GPT4->0x6000==xloader 读 LK 证书处(独立佐证)
#   - EMUI8 fw_hifi GPT25->LK27->0x1b000;旧 vrl_emui8certs 把 hifi 放 0x1c000、0x1b000 放 sensorhub => Func 8
#   - 纠正镜像 13 证书按 EMUI8 槽重排,hifi 证书 hash@0x74c==sha256(刷入本体),0 坏块
#
# 只写 vrl / vrl_backup。不写 ptable/efuse/oeminfo/frp/nvme/modem*/secure_storage/userdata。
# 拿不到 Writing OKAY 就停。**本脚本不 reboot** —— 写后由零写入读回校验,再决定重启。
# 读回校验单独跑 fbraw(避免与 flash 交错失步);本脚本只用 fastboot.exe。
set -u
cd "$(dirname "$0")/.." || exit 1
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
OUT="out_check/fixvrl_layout_$(date +%H%M%S)"; mkdir -p "$OUT"
exec >> >(tee "$OUT/run.log") 2>&1

IMG="fix_vrl/vrl_emui8_layout.img"
RST="fix_vrl/vrl_emui8certs.img"
WSHA="80416b0c43103e18f5c5c46c3d39f234f332fc740b51f2c827828f0cc41c8dbd"
RSHA="4c08ca686f472953f5deaeac787228b16e61fadbd781c98ed4eeaf513ec5a0be"

echo "[*] start $(date +%H:%M:%S)  vrl 槽位按 EMUI8 表序重排(写 vrl+vrl_backup,不 reboot)"

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

gate vrl_layout "$IMG" 262144 "$WSHA" || { echo "[x] 写入镜像校验不过,不写"; exit 3; }
gate vrl_restore "$RST" 262144 "$RSHA" || { echo "[x] 还原镜像缺失/损坏,不可逆,不写"; exit 3; }
echo "[+] 校验门通过(写入镜像 + 还原镜像都在手)"

if ! $FB devices 2>/dev/null | grep -q fastboot; then
  echo "[x] 现在没有 fastboot 通道 —— 先冷启动短接 + tools/pair_split.sh b186p,不写"; exit 4
fi
echo "[=] 通道在:$($FB devices 2>&1 | tr '\n' ' ')"

# 只读预检:吸收 LK 新连接丢首包;答不出期望值就不写。
echo "[=] 只读预检 max-download-size:"
pre=$(timeout 15 $FB getvar max-download-size 2>&1 | tr -d '\r\000')
echo "$pre" | sed 's/^/    /'
if ! echo "$pre" | grep -q "max-download-size: 471859200"; then
  echo "[!] 预检首问没答出,重问一次:"
  pre=$(timeout 15 $FB getvar max-download-size 2>&1 | tr -d '\r\000')
  echo "$pre" | sed 's/^/    /'
  if ! echo "$pre" | grep -q "max-download-size: 471859200"; then
    echo "[x] 预检没答出 471859200 —— 通道卡死,不写(零改动)"; exit 7
  fi
fi
echo "[+] 预检通过,通道活着"

flash_one() { # ptn
  local p="$1" o
  echo "[w] $(date +%H:%M:%S) flash $p  ($IMG)"
  o=$(timeout 120 $FB flash "$p" "$IMG" 2>&1); echo "$o" | sed 's/^/    /'
  if [ -z "$(echo "$o" | tr -d '[:space:]')" ]; then
    echo "[x] flash $p 返回空输出 —— exe 卡住被 timeout 杀掉,零改动,停"; return 6
  fi
  if echo "$o" | grep -qi "not allowed"; then
    echo "[x] $p 被拒(Command not allowed)—— 零改动,停"; return 5
  fi
  if ! echo "$o" | grep -q "Writing '$p'.*OKAY"; then
    echo "[x] 没拿到 Writing '$p' OKAY —— 停"; return 6
  fi
  echo "[+] $p Writing OKAY"
  return 0
}

flash_one vrl || exit $?
flash_one vrl_backup || exit $?

echo "[=] $(date +%H:%M:%S) 两份都拿到 Writing OKAY。**不 reboot**,下一步零写入读回校验:"
echo "    python tools/fbraw.py --outdir $OUT --cmd 'getvar storage:vrl' --cmd 'upload_storage:80000:40000'"
echo "    python tools/fbraw.py --outdir $OUT --cmd 'getvar storage:vrl_backup' --cmd 'upload_storage:c0000:40000'"
echo "    判据:两份读回 sha256 == $WSHA 才算落盘"
echo "[*] end $(date +%H:%M:%S) log=$OUT"