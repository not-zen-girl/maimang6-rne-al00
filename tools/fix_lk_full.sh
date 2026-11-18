#!/usr/bin/env bash
# 把 fastboot(LK)分区整块复原成本机正常工作时的样子。
# 依据:heads_live/fastboot.bin 是 11-15 手机还跑 B186 且有 root 时,
#      tools/probe_heads.js 用 adb shell dd if=/dev/block/mmcblk0 按活表 LBA 整块拉下来的 8192 扇区。
# 为什么不能只写 LK 镜像:本机该分区实际占用 3609120 B = LK(2702976) + 面板/DTB 数据 + 符号表,
#      而之前写 EMUI-8 的 dd_set/fastboot.img 长 2864640 B,覆盖掉了 LK 之后的 161664 B。
#      只写 2702976 B 修不回来。整块写回 = 逐字节复原。
set -u
cd "$(dirname "$0")/.." || exit 1
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
OUT="out_check/lkfull_$(date +%H%M%S)"; mkdir -p "$OUT"
exec >> >(tee "$OUT/run.log") 2>&1

IMG="heads_live/fastboot.bin"
echo "[*] start $(date +%H:%M:%S)  fastboot 分区整块复原(4 MB 本机 dump)"

python - "$OUT" <<'PY'
import hashlib,os,struct,sys,json
out=sys.argv[1]; p='heads_live/fastboot.bin'
b=open(p,'rb').read()
sha=hashlib.sha256(b).hexdigest()
man={e['name']:e for e in json.load(open('rb186/manifest.json',encoding='utf-8'))}
lke=man['fastboot']; lk=open('rb186/fastboot.img','rb').read()
g=open('rb186/efi.img','rb').read()
cap=None
for i in range(128):
    e=g[1024+i*128:1152+i*128]
    if e[:16]==b'\0'*16: continue
    f,l=struct.unpack('<QQ',e[32:48]); nm=e[56:128].decode('utf-16-le').rstrip('\0')
    if nm=='fastboot': cap=(f,l,(l-f+1)*512)
checks=[
 ('尺寸 == 8192 扇区 == 4194304 B', len(b)==4194304),
 ('活表 fastboot 分区容量一致',      cap is not None and cap[2]==len(b)),
 ('前 2702976 B == rb186/fastboot.img(官方 LK,剥前缀)', b[:len(lk)]==lk),
 ('rb186/fastboot.img 自身 sha 符合 manifest', hashlib.sha256(lk).hexdigest()==lke['sha256']),
 ('LK 头是 ARM64 跳转表 0d000014',   b[:4].hex()=='0d000014'),
 ('LK 之后仍有数据(面板/符号表,非全零)', len(b[:len(b.rstrip(b'\0'))])>3000000),
 ('尾部 512 KB 为零(与本机 dump 一致)', b[3670016:]==bytes(len(b)-3670016)),
]
gl=open(os.path.join(out,'gate.txt'),'w',encoding='utf-8')
bad=0
for lbl,ok in checks:
    gl.write('%s %s\n'%('OK ' if ok else 'BAD',lbl))
    if not ok: bad=1
gl.write('\n整块 sha256 = %s\n'%sha)
gl.write('实际占用 = %d B (LK %d B + 附加 %d B)\n'%(len(b.rstrip(b'\0')),len(lk),len(b.rstrip(b'\0'))-len(lk)))
gl.write('目标分区 LBA %d..%d\n'%(cap[0],cap[1]))
gl.close()
sys.exit(bad)
PY
rc=$?
sed 's/^/  gate| /' "$OUT/gate.txt"
if [ $rc -ne 0 ]; then echo "[x] 校验门没过,不写"; exit 3; fi
echo "[+] 校验门通过"

if ! $FB devices 2>/dev/null | grep -q fastboot; then
  echo "[x] 没有 fastboot 通道 —— 先短接进 COM1.0 再跑 tools/pair_split.sh b186p,不写"; exit 4
fi
echo "[=] 通道在:$($FB devices 2>&1 | tr '\n' ' ')"

echo "[w] $(date +%H:%M:%S) flash fastboot $IMG (4194304 B 整块)"
o=$(timeout 300 $FB flash fastboot "$IMG" </dev/null 2>&1); echo "$o" | sed 's/^/    /'
if echo "$o" | grep -qi "not allowed"; then echo "[x] 被拒,零改动,停"; exit 5; fi
if ! echo "$o" | grep -q "Writing 'fastboot'.*OKAY"; then echo "[x] 没拿到 Writing OKAY,不 reboot,停"; exit 6; fi

echo "[=] $(date +%H:%M:%S) reboot"
timeout 20 $FB reboot 2>&1 | tail -2 | sed 's/^/    /'

ids() { powershell -NoProfile -ExecutionPolicy Bypass -File tools/phone_ids.ps1 2>/dev/null | tr -d '\r' | tr '\n' ' '; }
for i in $(seq 1 30); do
  sleep 10
  s=$(ids)
  case "$s" in
    *PID_3609*) tag="下载口 COM1.0";;
    *PID_D00D*) tag="fastboot(自己起来的)";;
    "")         tag="不在总线上";;
    *)          tag="另一种枚举";;
  esac
  echo "  t+$((i*10))s  $tag  [$s]"
  case "$tag" in
    "fastboot(自己起来的)") echo "[+] 不用 RAM 载就自己进了 fastboot"
        timeout 8 $FB getvar product 2>&1 | sed 's/^/    /'; break;;
    "另一种枚举") echo "[+] 出现新枚举形态,可能系统起来了"; break;;
  esac
done
echo "[*] end $(date +%H:%M:%S) log=$OUT"