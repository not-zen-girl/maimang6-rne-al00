#!/bin/bash
# 只读探针：fetch 把分区镜像从设备读回文件。不写闪存，也不改任何配置。
# 前提：RAM 里已经载好了能答 fastboot 的那对（tools/pair_one.sh tool）。
# 判据：设备回什么算什么。能读回 vrl/vrl_backup 就第一次看到 LK 自己开工前必读的那份配置；
#        读不回就是设备侧否定，记下原文，不算"不支持"。
cd "C:/Users/64563/Desktop/maimang6" || exit 2
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
D="out_check/fetch_$(date +%H%M%S)"; mkdir -p "$D"; exec >> >(tee "$D/run.log") 2>&1
echo "[*] start $(date +%H:%M:%S)  只读,不写闪存"
$FB devices 2>/dev/null | grep -q fastboot || { echo "[x] 现在没有 fastboot,先跑 tools/pair_one.sh tool"; exit 5; }
for v in product version; do echo "[=] getvar $v → $($FB getvar "$v" 2>&1 | tr '\n' ' ')"; done
for n in vrl vrl_backup fastboot ptable efi misc bootfail_info; do
  o=$($FB fetch "$n" "$D/$n.img" 2>&1 | tr '\n' ' ')
  sz=""
  [ -f "$D/$n.img" ] && sz="$(wc -c < "$D/$n.img") B head=$(head -c 16 "$D/$n.img" | xxd -p)"
  echo "  fetch $n → ${o:0:170}"
  [ -n "$sz" ] && echo "         文件 $sz  sha=$(sha256sum "$D/$n.img" | cut -c1-16)…"
done
echo "[*] end $(date +%H:%M:%S) 目录=$D"