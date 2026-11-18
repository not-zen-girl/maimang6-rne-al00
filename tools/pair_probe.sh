#!/bin/bash
# 零写入判别：把 5.1 与 EMUI-8 两代的官方 xloader+LK **整对**载进 RAM，看哪一对能起 LK。
# 理由：deepflash 平时载的是工具自带的一对，所以 RAM 载入从没失败过；而盘里是 5.1 xloader + EMUI-8 LK 的混配。
# 能起 LK 的那一代，顺便问一次分区名图（只用两种未来都无所谓的名字，不写内容）。
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
PS="powershell -ExecutionPolicy Bypass -File rescue/deepflash/deepflash.ps1 -Port COM3"
B='C:\Users\64563\Desktop\maimang6'
X51="$B\rb186\xloader.img";        L51="$B\rb186\fastboot.img"
X8="$B\rb379\xloader_pure.img";   L8="$B\dd_set\fastboot.img"
OUT="out_check/pair_probe_$(date +%H%M%S)"; mkdir -p "$OUT"; exec >> >(tee "$OUT/run.log") 2>&1
echo "[*] start $(date +%H:%M:%S)  本脚本不写闪存内容"
up() { $FB devices 2>/dev/null | grep -q fastboot; }
ids() { powershell -NoProfile -Command "((Get-PnpDevice -PresentOnly | Where-Object { \$_.InstanceId -like '*VID_12D1*' -or \$_.InstanceId -like '*VID_18D1*' } | ForEach-Object { \$_.InstanceId }) -join ' ')" 2>/dev/null | tr -d '\r' | sed 's/USB.//g'; }
back_to_dl() { up && { $FB reboot 2>&1 | tail -1 | sed 's/^/  reboot| /'; sleep 25; }; return 0; }

asknames() {
  echo "  [名图] 用 $1 问哪些名字能解析（0 字节探针：发 0 字节,不写任何内容）"
  for n in boot recovery odm zzz_not_a_partition; do
    o=$($FB flash "$n" out_check/probe/zero.bin 2>&1 | tr '\n' ' ')
    echo "    $n → ${o:0:150}"
  done
}

try_pair() { # 代号 xloader lk
  local tag="$1" xl="$2" lk="$3" try out
  back_to_dl
  echo "===== $tag  xloader=$xl  lk=$lk  $(date +%H:%M:%S)"
  for try in 1 2 3; do
    out=$($PS -Plan "0x00020000=$xl;0x10000000=$lk" 2>&1 | iconv -f GBK -t UTF-8 2>/dev/null | tail -2 | sed "s/^/  load| /")
    echo "$out"
    echo "$out" | grep -q "拒绝" || break
    echo "    COM3 还被占着,等 15 秒重试 ($try/3)"; sleep 15
  done
  for i in 1 2 3 4 5 6; do
    sleep 5
    if up; then echo "  [+] $tag：LK 起来了,在答 fastboot"; asknames "$tag"; return 0; fi
    case "$(ids)" in *PID_3609*) : ;; *) echo "    t+$((i*5))s 非下载口枚举: $(ids)";; esac
  done
  echo "  [-] $tag：没有 fastboot。当前枚举=$(ids)"
  return 1
}

try_pair "B) EMUI-8 官方成对 (xloader_pure + dd_set LK)" "$X8" "$L8"
try_pair "A) 5.1 官方成对 (rb186 xloader + rb186 LK)" "$X51" "$L51"
echo "[*] end $(date +%H:%M:%S) log=$OUT"