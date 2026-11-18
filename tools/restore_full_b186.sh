#!/usr/bin/env bash
# 通过 RAM 载起来的 5.1 官方 LK(pair_split.sh b186p),把本机原装 B186 全套写回闪存。
# 布局锚定 rb186/efi.img —— 本机实 dump 的 5.1 活表,不是供体包。
# 每个文件都过 sha256+尺寸门(锚定 rb186/manifest.json),并核对装得进 5.1 分区。
# 任何一条拿不到 Writing OKAY 就停,不 reboot。
# 禁写:efuse oeminfo frp nvme modemnvm_* modem_om modem_secure secure_storage userdata vrl
set -u
cd "$(dirname "$0")/.." || exit 1
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
OUT="out_check/full51_$(date +%H%M%S)"; mkdir -p "$OUT"
exec >> >(tee "$OUT/run.log") 2>&1

echo "[*] start $(date +%H:%M:%S)  本机原装 B186 全套回写(5.1 布局)"
echo "[=] 客户端 $($FB --version 2>&1 | head -1)"

# ---------- 校验门 + 生成写入计划 ----------
python - "$OUT" <<'PY'
import json,hashlib,os,struct,sys
out=sys.argv[1]
man={e['name']:e for e in json.load(open('rb186/manifest.json',encoding='utf-8'))}
g=open('rb186/efi.img','rb').read()
cap={}
for i in range(128):
    e=g[1024+i*128:1152+i*128]
    if e[:16]==b'\0'*16: continue
    f,l=struct.unpack('<QQ',e[32:48]); nm=e[56:128].decode('utf-16-le').rstrip('\0')
    cap[nm]=(l-f+1)*512
ORDER=[('ptable','rb186/efi.img','efi'),
       ('xloader','rollback_b186/xloader.img',None),
       ('fastboot','rb186/fastboot.img','fastboot'),
       ('dts','rb186/dts.img','dts'),
       ('fw_lpm3','rb186/fw_lpm3.img','fw_lpm3'),
       ('sensorhub','rb186/sensorhub.img','sensorhub'),
       ('fw_hifi','rb186/fw_hifi.img','fw_hifi'),
       ('teeos','rb186/teeos.img','teeos'),
       ('trustfirmware','rb186/trustfirmware.img','trustfirmware'),
       ('modem_fw','rb186/modem_fw.img','modem_fw'),
       ('boot','rb186/boot.img','boot'),
       ('recovery','rb186/recovery.img','recovery'),
       ('recovery2','rb186/recovery2.img','recovery2'),
       ('cache','rb186/cache.img','cache'),
       ('system','rb186/system.img','system'),
       ('vendor','rb186/vendor.img','vendor'),
       ('product','rb186/product.img','product')]
FORBID={'efuse','oeminfo','frp','nvme','modemnvm_factory','modemnvm_backup','modemnvm_img',
        'modemnvm_system','modemnvm_update','modem_om','modem_secure','secure_storage',
        'userdata','vrl','vrl_backup'}
bad=0; lines=[]; total=0
gl=open(os.path.join(out,'gate.txt'),'w',encoding='utf-8')
def w(s):
    gl.write(s+'\n')
for part,path,mname in ORDER:
    if part in FORBID: w('BAD %-14s 在禁写清单里'%part); bad=1; continue
    if not os.path.exists(path): w('BAD %-14s 文件不存在 %s'%(part,path)); bad=1; continue
    b=open(path,'rb').read(); sz=len(b); sha=hashlib.sha256(b).hexdigest()
    if part=='xloader':
        # 落盘形态带 4096 前缀;剥掉后必须逐字节等于 manifest 里那件本机原装 xloader
        want=man['xloader']
        core=b[4096:]
        ok = (sz==69184 and sha=='27652e36f0948ebd80a0e1b198345d7dc6268164f523524035d25801eab96a16'
              and len(core)==want['size'] and hashlib.sha256(core).hexdigest()==want['sha256']
              and b[:8]==bytes.fromhex('0000000000000000'))
        w('%s %-14s %-32s size=%d sha=%s  剥前缀后==manifest xloader: %s'%(
            'OK ' if ok else 'BAD',part,path,sz,sha[:16],hashlib.sha256(core).hexdigest()==want['sha256']))
    else:
        e=man.get(mname)
        if e is None: w('BAD %-14s manifest 里没有 %s'%(part,mname)); bad=1; continue
        ok = (sz==e['size'] and sha==e['sha256'])
        c=cap.get(part)
        fit = (c is None) or (sz<=c)
        w('%s %-14s %-32s size=%d/%d sha=%s/%s  分区容量=%s 装得下=%s'%(
            'OK ' if (ok and fit) else 'BAD',part,path,sz,e['size'],sha[:16],e['sha256'][:16],
            c if c is not None else 'n/a(硬编码区/表本身)',fit))
        if not fit: bad=1
    if not ok: bad=1; continue
    total+=sz
    lines.append('%s\t%s\t%d'%(part,path,sz))
w('')
w('合计 %d 个文件, %d 字节 (%.2f GB)'%(len(lines),total,total/1073741824.0))
gl.close()
open(os.path.join(out,'plan.tsv'),'w',encoding='utf-8').write('\n'.join(lines)+'\n')
sys.exit(bad)
PY
rc=$?
sed 's/^/  gate| /' "$OUT/gate.txt"
if [ $rc -ne 0 ]; then echo "[x] 校验门没过,一条都不写"; exit 3; fi
echo "[+] 校验门通过"

# ---------- 通道确认 ----------
if ! $FB devices 2>/dev/null | grep -q fastboot; then
  echo "[x] 没有 fastboot 通道 —— 先短接进 COM1.0 再跑 tools/pair_split.sh b186p,不写"; exit 4
fi
echo "[=] 通道在:$($FB devices 2>&1 | tr '\n' ' ')"
timeout 8 $FB getvar max-download-size 2>&1 | sed 's/^/    /'

ids() { powershell -NoProfile -ExecutionPolicy Bypass -File tools/phone_ids.ps1 2>/dev/null | tr -d '\r' | tr '\n' ' '; }

# ---------- 逐条写 ----------
n_ok=0
while IFS=$'\t' read -r part path sz; do
  [ -z "${part:-}" ] && continue
  echo "[w] $(date +%H:%M:%S) flash $part  ($path, $sz B)"
  o=$(timeout 900 $FB flash "$part" "$path" </dev/null 2>&1); echo "$o" | sed 's/^/    /'
  if echo "$o" | grep -qi "not allowed"; then
    echo "[x] $part 被拒(Command not allowed)—— 停,已写 $n_ok 条,不 reboot"; exit 5
  fi
  if ! echo "$o" | grep -q "Writing '$part'.*OKAY"; then
    echo "[x] $part 没拿到 Writing OKAY —— 停在这里,已写 $n_ok 条,不 reboot"
    echo "[=] 若这是 ptable 之后的第一条按名字写入,可能是 LK 缓存了旧分区表;需重新载入再试"
    exit 6
  fi
  echo "$o" | grep -q "Writing '$part'.*OKAY \[  0.000s\]" && \
    echo "[!] $part 的 Writing 耗时 0.000s —— 疑似只 ACK 未落盘"
  n_ok=$((n_ok+1))
done < "$OUT/plan.tsv"
echo "[+] $n_ok 条全部拿到 Writing OKAY"

echo "[w] $(date +%H:%M:%S) erase misc (清掉 boot-to-recovery 标志)"
timeout 60 $FB erase misc 2>&1 | sed 's/^/    /'

echo "[=] $(date +%H:%M:%S) reboot"
timeout 20 $FB reboot 2>&1 | tail -2 | sed 's/^/    /'

# ---------- 有界观察 240 秒 ----------
for i in $(seq 1 24); do
  sleep 10
  s=$(ids)
  case "$s" in
    *PID_3609*) tag="下载口 COM1.0";;
    *PID_D00D*) tag="fastboot(自己起来的)";;
    "")         tag="不在总线上(可能在启动/仅充电)";;
    *)          tag="另一种枚举";;
  esac
  echo "  t+$((i*10))s  $tag  [$s]"
  case "$tag" in
    "fastboot(自己起来的)") echo "[+] 不用 RAM 载就自己进了 fastboot —— 写入落盘了"
        timeout 8 $FB getvar product 2>&1 | sed 's/^/    /'; break;;
    "另一种枚举") echo "[+] 出现新的枚举形态,可能是系统起来了"; break;;
  esac
done
echo "[*] end $(date +%H:%M:%S) log=$OUT"