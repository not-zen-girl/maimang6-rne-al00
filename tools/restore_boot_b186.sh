#!/usr/bin/env bash
# 用 RAM 载起来的 5.1 官方 LK(b186p),按 IDT 官方顺序写回本机原装引导件。
# 只写 xloader 和 fastboot 两个分区。不写 ptable/efuse/oeminfo/身份分区/userdata。
# 每一步都有 sha256+尺寸门;拿不到 Writing OKAY 就停,不 reboot。
set -u
cd "$(dirname "$0")/.." || exit 1
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
OUT="out_check/bootb186_$(date +%H%M%S)"; mkdir -p "$OUT"
exec >> >(tee "$OUT/run.log") 2>&1

echo "[*] start $(date +%H:%M:%S)  写回本机原装 5.1 引导件(xloader + fastboot)"

# ---- 校验门:尺寸 + sha256 + 前缀形态,全部锚定已验证的常量 ----
gate() { # name path wantsize wantsha wanthead
  local n="$1" p="$2" wsz="$3" wsha="$4" whd="$5"
  if [ ! -f "$p" ]; then echo "  gate| BAD $n 文件不存在 $p"; return 1; fi
  local sz got hd
  sz=$(wc -c < "$p" | tr -d ' ')
  got=$(sha256sum "$p" | cut -d' ' -f1)
  hd=$(head -c 8 "$p" | od -An -tx1 | tr -d ' \n')
  echo "  gate| $n $p size=$sz (期望 $wsz)"
  echo "  gate|   sha=$got"
  echo "  gate|   前 8 字节=$hd (期望 $whd)"
  if [ "$sz" != "$wsz" ] || [ "$got" != "$wsha" ] || [ "$hd" != "$whd" ]; then
    echo "  gate| BAD $n 校验不过"; return 1
  fi
  echo "  gate| OK  $n"; return 0
}

# xloader 落盘形态 = 带 4096 前缀(IDT PASS 日志里 sending 'xloader' 69 KB 就是带前缀的尺寸)
gate xloader "rollback_b186/xloader.img" 69184 \
  27652e36f0948ebd80a0e1b198345d7dc6268164f523524035d25801eab96a16 \
  0000000000000000 || { echo "[x] 校验门没过,一条都不写"; exit 3; }
# fastboot(LK)分区落盘形态 = 剥前缀,头是 ARM64 跳转表
gate fastboot "rb186/fastboot.img" 2702976 \
  45b529eb5a46dfaf1c75a6f103474691a5c81f8c793f8a347b34f8fe9f111504 \
  0d0000140c000014 || { echo "[x] 校验门没过,一条都不写"; exit 3; }
echo "[+] 校验门通过"

# ---- 通道确认:必须是手机自己在答 fastboot ----
if ! $FB devices 2>/dev/null | grep -q fastboot; then
  echo "[x] 现在没有 fastboot 通道 —— 先跑 tools/pair_split.sh b186p,不写"; exit 4
fi
echo "[=] 通道在:$($FB devices 2>&1 | tr '\n' ' ')"
echo "[=] 载入口只读复核 max-download-size:"
timeout 8 $FB getvar max-download-size 2>&1 | sed 's/^/    /'

ids() { powershell -NoProfile -ExecutionPolicy Bypass -File tools/phone_ids.ps1 2>/dev/null | tr -d '\r' | tr '\n' ' '; }

# ---- 按 IDT 顺序写 ----
for step in "xloader rollback_b186/xloader.img" "fastboot rb186/fastboot.img"; do
  set -- $step; n="$1"; img="$2"
  echo "[w] $(date +%H:%M:%S) flash $n  ($img)"
  o=$(timeout 120 $FB flash "$n" "$img" 2>&1); echo "$o" | sed 's/^/    /'
  if echo "$o" | grep -qi "not allowed"; then
    echo "[x] $n 被拒(Command not allowed)—— 这个 LK 不许写,零改动,停"; exit 5
  fi
  if ! echo "$o" | grep -q "Writing '$n'.*OKAY"; then
    echo "[x] $n 没拿到 Writing OKAY —— 停在这里,后面不写,不 reboot"; exit 6
  fi
  # 0.000s 写 2.6MB 物理上不可能 => 记下这个疑点,但继续(reboot 后的现象才是真判据)
  if echo "$o" | grep -q "Writing '$n'.*OKAY \[  0.000s\]"; then
    echo "[!] $n 的 Writing 耗时 0.000s —— 疑似只 ACK 未落盘,继续看 reboot 结果"
  fi
done

echo "[=] $(date +%H:%M:%S) 两条都拿到 Writing OKAY,reboot"
timeout 20 $FB reboot 2>&1 | tail -2 | sed 's/^/    /'

# ---- 有界观察 180 秒:自己回到 fastboot / 起来 / 还是下载口 ----
for i in $(seq 1 18); do
  sleep 10
  s=$(ids)
  case "$s" in
    *PID_3609*) tag="下载口 COM1.0";;
    *PID_D00D*) tag="fastboot(自己起来的!)";;
    "")         tag="不在总线上";;
    *)          tag="另一种枚举";;
  esac
  echo "  t+$((i*10))s  $tag  [$s]"
  if [ "$tag" = "fastboot(自己起来的!)" ]; then
    echo "[+] 手机 without RAM load 自己进了 fastboot —— 写入真的落盘了"
    timeout 8 $FB getvar product 2>&1 | sed 's/^/    /'
    break
  fi
done
echo "[*] end $(date +%H:%M:%S) log=$OUT"