#!/bin/bash
# 补回官方 EMUI-8 引导集 + 被抹掉的 odm。
# 背景:20:11 写对过这五张,但当时盘里 LK 是坏的(带 4096 前缀);20:33/20:39 又用 5.1 TWRP 覆盖了
# dts/kernel/ramdisk/recovery_ramdisk;22:12 才把 LK 修好。所以"官方 LK + 官方 kernel/ramdisk/dts"
# 从来没有同时在盘里存在过。这一轮就是让它们第一次同时在场。
# 通道:RAM 里的工程 LK(23:19 载入),它已证明能真写盘(22:12 flash fastboot → Writing OKAY)。
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
NAMES="dts kernel ramdisk recovery_ramdisk odm recovery_vendor"
OUT="out_check/restore8_$(date +%H%M%S)"; mkdir -p "$OUT"; exec >> >(tee "$OUT/run.log") 2>&1
echo "[*] start $(date +%H:%M:%S)  6 条带 sha 门的写入(锚定 dd_set/manifest.json)"

python - <<'PY' > "$OUT/gate.txt" 2>&1
import json, hashlib, os, sys
m = json.load(open('dd_set/manifest.json', encoding='utf-8'))
names = ['dts', 'kernel', 'ramdisk', 'recovery_ramdisk', 'odm', 'recovery_vendor']
bad = 0
for n in names:
    e = [x for x in m if x['name'] == n]
    if len(e) != 1:
        print('BAD %-18s manifest_entries=%d' % (n, len(e))); bad = 1; continue
    e = e[0]; p = 'dd_set/%s.img' % n
    if not os.path.isfile(p):
        print('BAD %-18s missing_file' % n); bad = 1; continue
    sz = os.path.getsize(p)
    h = hashlib.sha256(open(p, 'rb').read()).hexdigest()
    ok = (sz == e['size'] and h == e['sha256'])
    print('%s %-18s size=%d/%d sha=%s/%s first=%d sectors=%d' % (
        'OK ' if ok else 'BAD', n, sz, e['size'], h[:16], e['sha256'][:16], e['first'], e['sectors']))
    if not ok: bad = 1
sys.exit(bad)
PY
rc=$?
sed 's/^/  gate| /' "$OUT/gate.txt"
if [ $rc -ne 0 ]; then echo "[x] 校验门没过,一条都不写"; echo "[*] end $(date +%H:%M:%S) log=$OUT"; exit 3; fi
echo "[+] 6 条全部对上 manifest"

up()  { $FB devices 2>/dev/null | grep -q fastboot; }
ids() { powershell -NoProfile -ExecutionPolicy Bypass -File tools/phone_ids.ps1 2>/dev/null | tr -d '\r' | tr '\n' ' '; }
if ! up; then echo "[x] 现在没有 fastboot,RAM 里的工程 LK 掉了。先跑 tools/pair_split.sh tool"; echo "[*] end $(date +%H:%M:%S) log=$OUT"; exit 4; fi
echo "[=] 通道在:$($FB devices 2>&1 | head -1)"

for n in $NAMES; do
  echo "[w] $(date +%H:%M:%S) flash $n  $(wc -c < "dd_set/$n.img") B"
  o=$($FB flash "$n" "dd_set/$n.img" 2>&1)
  echo "$o" | sed 's/^/    /'
  if ! echo "$o" | grep -q "Writing '$n'.*OKAY"; then
    echo "[x] $n 没拿到 Writing OKAY —— 停在这里,后面几条不写"
    echo "[*] end $(date +%H:%M:%S) log=$OUT"; exit 5
  fi
done
echo "[+] 6 条全部 Writing OKAY"

echo "[=] $(date +%H:%M:%S) reboot —— 这是第一次让官方 LK+官方 kernel/ramdisk/dts+官方 odm 同时在盘里"
echo "[=] 请看手机屏幕:有没有华为 logo / 开机动画 / 任何字"
$FB reboot 2>&1 | tail -1 | sed 's/^/    /'

echo "[=] 观察 180 秒(前 60 秒不下结论)"
for i in $(seq 1 18); do
  sleep 10
  s=$(ids)
  case "$s" in
    *PID_3609*) tag="下载口 COM1.0";;
    *PID_D00D*) tag="fastboot";;
    "")         tag="不在总线上";;
    *)          tag="另一种枚举";;
  esac
  if [ $((i*10)) -le 60 ]; then pre="宽限期内不下结论; "; else pre=""; fi
  echo "  t+$((i*10))s ${pre}${tag}: ${s:-（无）}"
  if [ $((i*10)) -ge 60 ]; then
    case "$s" in
      *PID_108A*|*PID_1037*|*PID_107D*) echo "[+] 出现系统侧枚举,可能起来了";;
    esac
  fi
done
echo "[*] end $(date +%H:%M:%S) log=$OUT"