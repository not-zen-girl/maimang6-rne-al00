#!/bin/bash
# 整套回到 5.1:引导链全部用 B186 自己的镜像,按 5.1 的分区名写入。
# 本次唯一目标 = 让 LK 至少"尝试加载一次";recovery 位放已验证过的 5.1 TWRP,
# 为的是万一它起来了,我就能拿到 shell 去读 GPT/vrl,而不是继续猜。
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
A="./platform-tools/adb.exe -L tcp:5039"
PS="powershell -ExecutionPolicy Bypass -File rescue/deepflash/deepflash.ps1 -Port COM3"
XL="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_xloader.img"
LK="C:\\Users\\64563\\Desktop\\maimang6\\rescue\\tools\\hisi\\hisi65x_b_fastboot.img"
OUT="out_check/full51_$(date +%H%M%S)"; mkdir -p "$OUT"; exec >> >(tee "$OUT/run.log") 2>&1
echo "[*] start $(date +%H:%M:%S)"

ids_now() { powershell -NoProfile -Command "((Get-PnpDevice -PresentOnly | Where-Object { \$_.InstanceId -like '*VID_12D1*' -or \$_.InstanceId -like '*VID_18D1*' } | ForEach-Object { \$_.InstanceId }) -join ' ')" 2>/dev/null | tr -d '\r'; }
load() { $PS -Plan "0x00020000=$XL;0x10000000=$LK" 2>&1 | tail -1 | sed 's/^/  load| /'; }
up() { $FB devices 2>/dev/null | grep -q fastboot; }

# name|file|sha256  (boot/recovery/recovery2/dts/xloader 取自 rb186/plan.json;
# fastboot 同样取 rb186;recovery 例外:放已验证过的 5.1 TWRP)
SETS=(
 "boot|rb186/boot.img|f95a4c094d134c97ed3794484459d31932c6903e5f5ce224e78cd0d099e6243e"
 "recovery|twrp_rne_emui51.img|52f67da4f7fa37536060778afe927cbaca8ff8b907896dfa243deb67cc70fbf6"
 "recovery2|rb186/recovery2.img|f01335f10a6a2d4f2f58d1cffa5cb0985bccaec4dcd12a0cda66bef31972b166"
 "dts|rb186/dts.img|d62cb45f6b2b563b34a15816bf9064c7116f3c4cc04ccfc9d4fd7e330afeb815"
 "xloader|rb186/xloader.img|b3a4fd4df9d9538ba5f4b9da11905973e1ad66e89c5de6a74a4cb80284949af9"
 "fastboot|rb186/fastboot.img|45b529eb5a46dfaf1c75a6f103474691a5c81f8c793f8a347b34f8fe9f111504"
)

up || load
up || { echo "[!] 没有 fastboot 通道,中止"; echo "[*] end $(date +%H:%M:%S)"; exit 3; }

for e in "${SETS[@]}"; do
  IFS='|' read -r name file want <<< "$e"
  got=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1)
  if [ "$got" != "$want" ]; then
    echo "[x] $name 哈希不符,中止(不动闪存) file=$file"
    echo "    期望 $want"
    echo "    实到 ${got:-无此文件}"
    echo "[*] end $(date +%H:%M:%S) log=$OUT"; exit 4
  fi
  up || load
  up || { echo "[x] $name 之前失去 fastboot,中止"; echo "[*] end $(date +%H:%M:%S) log=$OUT"; exit 5; }
  sz=$(stat -c %s "$file")
  echo "[=] $(( $(date +%s) )) $(date +%H:%M:%S) flash $name  $sz B  sha OK"
  out=$($FB flash "$name" "$file" 2>&1)
  echo "$out" | tail -3 | sed 's/^/    /'
  if echo "$out" | grep -qiE 'FAIL|not exist|not found|error'; then
    echo "[x] $name 写入被拒 —— 分区名解析不到,中止(后面的不写)"
    echo "[*] end $(date +%H:%M:%S) log=$OUT"; exit 6
  fi
done

echo "[+] 6 条全部写完 $(date +%H:%M:%S),引导链现在=5.1(xloader/LK/dts/boot)+TWRP 在 recovery 位"
echo "[*] 现在盘里的 LK 是 5.1 的;下面的 reboot 是第一次真正的 5.1 自举"
out=$($FB reboot recovery 2>&1); echo "$out" | tail -2 | sed 's/^/  reboot recovery| /'
if echo "$out" | grep -qi FAIL; then
  echo "[!] 这个 LK 不接受 reboot recovery,改普通启动"; $FB reboot 2>&1 | tail -1 | sed 's/^/  reboot| /'
fi
dl=0
for i in $(seq 1 30); do
  sleep 10
  adb=$($A devices 2>/dev/null | grep -cw device)
  if [ "$adb" != "0" ]; then echo "[+] ADB 上线 t+$((i*10))s $(date +%H:%M:%S)"; sleep 8; bash tools/capture_state.sh; echo "[*] end $(date +%H:%M:%S)"; exit 0; fi
  if [ "$i" -ge 6 ]; then
    case "$(ids_now)" in
      *PID_3609*) dl=$((dl+1)); echo "  t+$((i*10))s 下载口在场(连续 $dl 次)"; [ "$dl" -ge 2 ] && { echo "  → 判定终止:仍是直奔下载口"; break; };;
      *PID_D00D*) dl=0; echo "  t+$((i*10))s 落到 fastboot(LK 在等命令)";;
      *) dl=0; echo "  t+$((i*10))s 无下载口,仍在启动中";;
    esac
  else
    echo "  t+$((i*10))s (宽限期内,不下结论)"
  fi
done
echo "[!] 全 5.1 之后仍没有 shell"
echo "[*] end $(date +%H:%M:%S) log=$OUT"