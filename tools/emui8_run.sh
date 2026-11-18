#!/system/bin/sh
# Hand-write the EMUI 8 (C00B379) payload onto a running EMUI 5.1 RNE-AL00, from TWRP.
# Nothing is written unless a phase is named. Read-back sha256 gates every write.
#   preflight  read-only: tools, battery, live GPT still matches the plan, 4096-byte convention
#   verify     sha256 every payload on the card            (read-only, ~5 GB)
#   phase1     all partitions that do not kill the running TWRP first, the boot/recovery ones last
#   phase2     the second-stage loader (fastboot), after every filesystem payload has landed
#   phase3     erase BCB + wipe the userdata head
#   phase4     the GPT flip - irreversible, needs CONFIRM=FLIP
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/params.sh"
DISK=${DISK:-/dev/block/mmcblk0}
PLAN="$DIR/plan.txt"
OUT="$DIR/out"
LOG="$OUT/log.txt"
mkdir -p "$OUT" 2>/dev/null

log() { echo "$*" | tee -a "$LOG"; }
die() { log "!! $*"; log "ABORT"; exit 1; }
hfile() { h=$(sha256sum "$1" 2>/dev/null); echo "${h%% *}"; }
hdev() { h=$(dd if="$DISK" bs="$1" skip="$2" count="$3" 2>/dev/null | sha256sum); echo "${h%% *}"; }
hzero() { h=$(dd if=/dev/zero bs="$1" count="$2" 2>/dev/null | sha256sum); echo "${h%% *}"; }

umount_all() {
  for d in $(grep mmcblk0 /proc/mounts | cut -d' ' -f2 | sort -r); do umount -l "$d" 2>/dev/null; done
  for d in /vendor /system /product /cust /preas /preavs /version /odm /cache /data /linkerconfig /mnt/vendor/*; do umount -l "$d" 2>/dev/null; done
}

check_plan() {
  [ -f "$PLAN" ] || die "找不到 $PLAN"
  planhash=$(hfile "$PLAN")
  [ "$planhash" = "$PLAN_SHA" ] || die "plan.txt 不完整 ($planhash != $PLAN_SHA)，卡上的拷贝没做完"
}

check_head() { # name lba must|info
  got=$(hdev 512 "$2" 128)
  full=$(hfile "$DIR/refs/${1}_full_head.bin")
  strip=$(hfile "$DIR/refs/${1}_strip_head.bin")
  if [ "$got" = "$strip" ]; then v=STRIPPED
  elif [ "$got" = "$full" ]; then v=VERBATIM
  else v=NEITHER; fi
  log "  $1 @ LBA $2: $v  (STRIPPED=分区里是去掉 4096 入口头的内容)"
  log "    live  =$got"
  log "    strip =$strip"
  if [ "$3" = must ] && [ "$v" != STRIPPED ]; then
    die "$1 判定成 $v，和建 dd 集时的依据不符，停下别写"
  fi
  return 0
}

calibrate() {
  log "-- 4096 入口头约定：只信我们从没写过的分区 --"
  check_head recovery2 "$OLD_RECOVERY2_LBA" must
  check_head teeos "$OLD_TEEOS_LBA" must
  check_head fw_hifi "$OLD_FW_HIFI_LBA" must
  check_head boot "$OLD_BOOT_LBA" info
}


case "${1:-status}" in
preflight)
  log "== preflight $(date) =="
  [ "$(id -u)" = 0 ] || die "不是 root"
  command -v sha256sum >/dev/null || die "recovery 里没有 sha256sum"
  [ -b "$DISK" ] || die "$DISK 不存在"
  cap=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || cat /sys/class/power_supply/Battery/capacity 2>/dev/null)
  log "battery ${cap:-?}%  $(cat /sys/class/power_supply/battery/status 2>/dev/null || cat /sys/class/power_supply/Battery/status 2>/dev/null)"
  [ -n "${cap:-}" ] && [ "$cap" -lt 40 ] && die "电量低于 40%，先充电"
  log "kernel: $(cat /proc/sys/kernel/ostype 2>/dev/null) $(uname -r)"
  got=$(hdev 512 0 34)
  [ "$got" = "$LIVE_GPT_SHA" ] || die "当前分区表 sha256 和建表时不一致（$got），plan 里的 LBA 不能再信"
  log "live GPT sha256 ok"
  check_plan
  log "-- 写在 mmcblk0 上的挂载 --"; grep mmcblk0 /proc/mounts | tee -a "$LOG"
  calibrate
  log "-- 一级引导区预备份（只读，xloader 就在这两个 HW 区里，我们不动它们）--"
  for b in 0 1; do
    if dd if=/dev/block/mmcblk0boot$b of="$OUT/mmcblk0boot$b.bin" bs=1048576 2>>"$LOG"; then
      log "  boot$b sha256 $(hfile "$OUT/mmcblk0boot$b.bin")"
    fi
  done
  log "-- 转存 4 MB 引导区给 PC 看 xloader 的摆位 --"
  dd if="$DISK" of="$OUT/fastboot_part.bin" bs=512 skip="$OLD_FASTBOOT_LBA" count="$OLD_FASTBOOT_COUNT" 2>>"$LOG" && log "  -> $OUT/fastboot_part.bin"
  log "== preflight done，没有写入任何东西 =="
  ;;

verify)
  check_plan
  log "== verify payloads on card $(date) =="
  n=0
  while IFS='|' read -r ph name src bs seek count sha; do
    case "$ph" in \#*) continue ;; esac
    [ "$src" = ZERO ] && continue
    [ -f "$DIR/$src" ] || die "缺 $src"
    got=$(hfile "$DIR/$src")
    [ "$got" = "$sha" ] || die "$name 卡上的文件坏了 got=$got want=$sha"
    n=$((n + 1))
    [ $((n % 5)) = 0 ] && log "  $n ok"
  done < "$PLAN"
  log "  $n payloads ok"
  echo ok > "$OUT/verified"
  ;;

phase1 | phase2 | phase3 | phase4)
  ph_n=${1#phase}
  check_plan
  [ -f "$OUT/verified" ] || die "先跑 verify"
  if [ "$ph_n" = 4 ] && [ "${CONFIRM:-}" != "FLIP" ]; then
    die "phase4 翻分区表不可逆（boot/recovery/recovery2/reserved7 四个名字从此消失）。确认要翻就用 CONFIRM=FLIP 再执行一次"
  fi
  log "== phase $ph_n start $(date) =="
  umount_all
  grep mmcblk0 /proc/mounts | tee -a "$LOG"
  n=0
  while IFS='|' read -r ph name src bs seek count sha; do
    case "$ph" in \#*) continue ;; esac
    [ "$ph" = "$ph_n" ] || continue
    n=$((n + 1))
    if [ "$src" = ZERO ]; then
      want=$(hzero "$bs" "$count")
      dd if=/dev/zero of="$DISK" bs="$bs" seek="$seek" count="$count" </dev/null 2>>"$LOG" || die "$name 写入失败"
      sync
      got=$(hdev "$bs" "$seek" "$count")
      [ "$got" = "$want" ] || die "$name 回读不是全零 got=$got"
      log "  zero $name  bs=$bs seek=$seek count=$count  ok"
      continue
    fi
    [ -f "$DIR/$src" ] || die "缺 $src"
    dd if="$DIR/$src" of="$DISK" bs="$bs" seek="$seek" count="$count" </dev/null 2>>"$LOG" || die "$name 写入失败"
    sync
    got=$(hdev "$bs" "$seek" "$count")
    [ "$got" = "$sha" ] || die "$name 回读校验失败 want=$sha got=$got"
    log "  ok $name  bs=$bs seek=$seek count=$count"
  done < "$PLAN"
  [ "$n" -gt 0 ] || die "phase $ph_n 一行都没匹配上：plan 或相位号不对，没写任何东西"
  sync
  log "== phase $ph_n done: $n writes $(date) =="
  ;;

status)
  echo "dir=$DIR disk=$DISK verified=$([ -f "$OUT/verified" ] && echo yes || echo no)"
  [ -f "$LOG" ] && tail -20 "$LOG"
  ;;

*)
  echo "usage: $0 {preflight|verify|phase1|phase3|phase4|status}"
  echo "phase4 需要 CONFIRM=FLIP"
  ;;
esac