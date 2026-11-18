#!/usr/bin/env bash
# Staged EMUI8 B379 flash through the official 5.1 LK channel.
#   s1 = flip ptable to the EMUI8 GPT, reboot back to bootloader, watch the bus
#   s2 = boot chain (first row erecovery_vbmeta doubles as the name-resolution probe)
#   s3 = big filesystem partitions (system/vendor sent as package sparse, auto-chunked)
#   s4 = erase misc, reboot, bounded observation
# Every artifact was gated by tools/emui8_gate.py (size + sha256 + partition capacity).
# Forbidden and never touched: efuse oeminfo frp nvme modemnvm_* modem_om modem_secure
#                              secure_storage userdata vrl_backup
# Any write without "Writing OKAY" stops the stage; no reboot is issued on failure.
set -u
cd "$(dirname "$0")/.." || exit 1
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
ADB="./rescue/tools/mrt/x1/program/addon/adb.exe"
GATE="out_check/emui8_gate"
STAGE="${1:-}"
case "$STAGE" in s1|s2|s3|s4) ;; *) echo "usage: $0 s1|s2|s3|s4"; exit 2;; esac
OUT="out_check/emui8_${STAGE}_$(date +%H%M%S)"; mkdir -p "$OUT"
exec >> >(tee "$OUT/run.log") 2>&1

echo "[*] $(date +%H:%M:%S) stage=$STAGE log=$OUT"

if ! grep -q '^RESULT: PASS' "$GATE/gate.txt"; then
  echo "[x] gate is not PASS -- nothing will be written"; exit 3
fi
echo "[+] gate PASS ($(grep -c '^OK ' "$GATE/gate.txt") artifacts)"

ids() { powershell -NoProfile -ExecutionPolicy Bypass -File tools/phone_ids.ps1 2>/dev/null | tr -d '\r' | tr '\n' ' '; }

fb() {  # fb <timeout> <args...>  -> output captured to a file, never piped live
  local t="$1"; shift
  local f="$OUT/cmd_$(echo "$*" | tr ' /:' '___').log"
  timeout "$t" "$FB" "$@" </dev/null >"$f" 2>&1
  tr -d '\000\r' < "$f"
}

fbr() {  # read-only commands: the LK drops the first packet on a new connection, re-ask
  local t="$1"; shift
  local o k
  for k in 1 2 3; do
    o=$(fb "$t" "$@")
    [ -n "$(echo "$o" | tr -d '[:space:]')" ] && { echo "$o"; return 0; }
  done
  echo "$o"; return 1
}

channel() {
  local d
  d=$("$FB" devices 2>/dev/null)
  echo "$d" | grep -q fastboot || { echo "[x] no fastboot channel: [$d]"; return 1; }
  echo "[=] channel: $(echo "$d" | tr '\n' ' ')"
  local i o
  for i in 1 2 3; do
    o=$(fb 10 getvar max-download-size)
    echo "$o" | sed 's/^/    /'
    echo "$o" | grep -q 'max-download-size' && return 0
    echo "[=] no answer (lost first packet?), re-ask $i"
  done
  echo "[x] getvar never answered"; return 1
}

write_row() { # write_row <part> <path> <size>
  local part="$1" path="$2" sz="$3" o t0 t1 el k
  for k in 1 2 3; do
    o=$(fb 15 getvar max-download-size)
    echo "$o" | grep -q '471859200' && break
  done
  if ! echo "$o" | grep -q '471859200'; then
    echo "[x] pre-flight never answered before $part -- STOP, no write"; return 4
  fi
  echo "[w] $(date +%H:%M:%S) flash $part  ($path, $sz B)"
  t0=$(date +%s%N)
  o=$(fb 1200 flash "$part" "$path")
  t1=$(date +%s%N); el=$(( (t1-t0)/1000000 ))
  echo "    elapsed=${el}ms"
  echo "$o" | sed 's/^/    /'
  if [ -z "$(echo "$o" | tr -d '[:space:]')" ] && [ "$el" -ge 1199000 ]; then
    echo "[x] $part HUNG (empty output, elapsed==timeout) -- killing client, STOP"
    taskkill //F //IM fastboot.exe >/dev/null 2>&1
    return 9
  fi
  if echo "$o" | grep -qi 'not allowed'; then
    echo "[x] $part refused (Command not allowed) -- STOP, no reboot"; return 5
  fi
  if echo "$o" | grep -qiE 'unknown partition|partition.*not found|no such partition|invalid partition|partition is not exist'; then
    echo "[x] $part name not resolved -- LK still holds the OLD table; STOP, no reboot"; return 7
  fi
  if echo "$o" | grep -qiE 'FAILED|remote error|too large'; then
    echo "[x] $part FAILED -- STOP, no reboot"; return 6
  fi
  if ! echo "$o" | grep -q "Writing '$part'.*OKAY"; then
    echo "[x] $part got no Writing OKAY -- STOP, no reboot"; return 6
  fi
  if echo "$o" | grep -q "Writing '$part'.*OKAY \[  0.000s\]"; then
    echo "[!] $part Writing took 0.000s -- suspicious ACK-only, STOP"; return 8
  fi
  echo "[+] $part OK"
  return 0
}

stage_rows() { grep -P "^$STAGE\t" "$GATE/plan.tsv" | tr -d '\r'; }

# The on-flash LK reads the real LOCKED state from oeminfo; only the USB-download /
# RAM-loaded path forces fb_lock_stat=1 (hwdog_certify @0x090f14, getmode()==0 branch).
# All probes go through fastboot.exe: interleaving fbraw.py desynchronises it and the
# next flash hangs forever (measured 22:05, zero bytes written, 9.5 min stuck).
unlock_gate() {
  local o
  o=$(fbr 15 oem device info)
  echo "$o" | sed 's/^/    lock| /'
  if echo "$o" | grep -q 'FB LockState: UNLOCKED'; then
    echo "[+] FB LockState UNLOCKED -- this channel may write"; return 0
  fi
  echo "[x] channel is NOT UNLOCKED -- refusing to write anything"; return 1
}

# Read-only name resolution. EMUI8: kernel@1b800000 system@4d800000, boot absent.
# B186: kernel unresolvable, system@40000000, boot@1b000000.
ptn_probe() {
  local tag="$1" v o
  : > "$OUT/ptn_$tag.txt"
  for v in kernel system boot; do
    o=$(fbr 15 getvar "storage:$v")
    echo "storage:$v -> $(echo "$o" | tr '\n' ' ')" >> "$OUT/ptn_$tag.txt"
  done
  sed 's/^/    ptn| /' "$OUT/ptn_$tag.txt"
}

table_emui8() {
  local f="$OUT/ptn_$1.txt"
  grep -q 'storage:kernel ->.*1b800000' "$f" || { echo "[x] kernel is not at the EMUI8 address"; return 1; }
  grep -q 'storage:system ->.*4d800000' "$f" || { echo "[x] system is not at the EMUI8 address"; return 1; }
  echo "[+] live partition table IS the EMUI8 GPT -- names resolve to the right addresses"
  return 0
}

case "$STAGE" in
s1)
  channel || exit 4
  unlock_gate || exit 9
  echo "[=] bus before: $(ids)"
  read -r st part path sz <<< "$(stage_rows)"
  [ "$part" = ptable ] || { echo "[x] first s1 row is not ptable"; exit 3; }
  echo "[=] BEFORE flip (read-only name resolution)"
  ptn_probe before
  write_row "$part" "$path" "$sz" || exit $?
  echo "[=] AFTER flip (read-only) -- did the running LK re-read the table?"
  ptn_probe after
  if table_emui8 after; then
    echo "[+] LIVE RELOAD -- no reboot needed, s2 can run in this same RAM-loaded session"
    echo "[*] s1 done $(date +%H:%M:%S). Next: bash tools/flash_emui8.sh s2"
    exit 0
  fi
  echo "[!] running LK still holds the OLD table -- a reload is required before s2"
  echo "[w] $(date +%H:%M:%S) reboot (plain, to encourage the BootROM COM1.0 fallback)"
  fb 25 reboot | sed 's/^/    /'
  echo "[=] bounded bus watch 180s"
  for i in $(seq 1 18); do
    sleep 10
    s=$(ids)
    case "$s" in
      *PID_3609*) tag="COM1.0 download port";;
      *PID_D00D*) tag="FASTBOOT";;
      *PID_107E*) tag="booted system / eRecovery";;
      "")         tag="off bus";;
      *)          tag="other enumeration";;
    esac
    echo "  t+$((i*10))s  $tag  [$s]"
    if [ "$tag" = FASTBOOT ]; then
      echo "[!] back in fastboot -- check whether it is UNLOCKED before doing anything else"
      fb 10 getvar max-download-size | sed 's/^/    /'
      break
    fi
    if [ "$tag" = "COM1.0 download port" ]; then
      echo "[+] landed in COM1.0 -- RAM-load b186p again, then s2"
      break
    fi
  done
  echo "[*] s1 done $(date +%H:%M:%S). s2 will refuse to write unless the EMUI8 table is live."
  ;;
s2|s3)
  channel || exit 4
  unlock_gate || exit 9
  ptn_probe gate
  table_emui8 gate || { echo "[x] stale/unknown partition table -- writing now would hit WRONG addresses"; exit 7; }
  n=0
  while IFS=$'\t' read -r st part path sz; do
    [ -z "${part:-}" ] && continue
    write_row "$part" "$path" "$sz"; rc=$?
    if [ $rc -ne 0 ]; then echo "[x] stage $STAGE stopped after $n writes"; exit $rc; fi
    n=$((n+1))
  done <<< "$(stage_rows)"
  echo "[+] stage $STAGE: $n writes all OKAY  $(date +%H:%M:%S)"
  ;;
s4)
  channel || exit 4
  echo "[w] $(date +%H:%M:%S) erase misc (clear boot-to-recovery flag)"
  fb 90 erase misc | sed 's/^/    /'
  echo "[=] userdata is NOT touched (forbidden). If EMUI8 needs a wipe, that is a separate approval."
  echo "[w] $(date +%H:%M:%S) reboot"
  fb 25 reboot | sed 's/^/    /'
  echo "[=] bounded observation 300s"
  for i in $(seq 1 30); do
    sleep 10
    s=$(ids)
    case "$s" in
      *PID_3609*) tag="COM1.0 download port";;
      *PID_D00D*) tag="FASTBOOT";;
      *PID_107E*) tag="BOOTED (system or eRecovery)";;
      "")         tag="off bus";;
      *)          tag="other enumeration";;
    esac
    a=$("$ADB" devices 2>/dev/null | grep -w device | tr '\n' ' ')
    echo "  t+$((i*10))s  $tag  [$s]  adb=[$a]"
    case "$tag" in
      "BOOTED (system or eRecovery)") echo "[+] phone enumerated as a booted device -- look at the screen"; break;;
      FASTBOOT) echo "[!] fell back to fastboot -- boot chain rejected something"; break;;
      "COM1.0 download port") echo "[!] fell to COM1.0 -- xloader/LK/vrl mismatch"; break;;
    esac
  done
  echo "[*] s4 done $(date +%H:%M:%S)"
  ;;
esac