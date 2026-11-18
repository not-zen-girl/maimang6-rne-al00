#!/usr/bin/env bash
# 零写入只读诊断。命令名全部从 rb186/fastboot.img(本机原装 5.1 LK)的字符串表里挖出来,
# 不是猜的。目的:回答三个悬案 —— 电池是否耗尽 / eMMC 是否写保护 / 上一次启动失败记录在哪一级。
#
# 为什么现在才做:整晚只用了 getvar+flash+reboot。LK 里另有一整套 oem 诊断命令,
# 其中 get_noboot_reason 会打印 "Boot fail @ BL1/BL2/Kernel/..." + bootFailErrno:0x%x,
# BL1=BootROM,BL2=xloader —— 正好是我们一直无法观测的那两级。
#
# 安全边界(硬白名单,见 ALLOW 函数):
#   绝不发 flash / erase / reboot / boot / continue / download / ultraflash / fetch。
#   绝不发 oem read 与 oem write —— 名字像读,实现是 read_write_test()/write_read_test(),会写盘。
#   绝不发 oem wrefuse / efuse_ / erase_storage_all / oeminfowrite / oeminfoerase /
#          sec_unlock / sec_relock / enable_crypt / disable_crypt / set_* / ddrtest / dmatest。
#   oem emmc-dump 语义未确认,不用;只用 emmc_diag(实现函数名 emmc_rdonly_diag,只读)。
set -u
cd "$(dirname "$0")/.." || exit 1
FB="./rescue/tools/mrt/x1/program/addon/fastboot.exe"
OUT="out_check/oemdiag_$(date +%H%M%S)"; mkdir -p "$OUT"
exec >> >(tee "$OUT/run.log") 2>&1
echo "[*] start $(date +%H:%M:%S)  只读 oem 诊断,零写入"

# 白名单:只有这些字符串能进 fastboot 命令行。
ALLOW() {
  case "$1" in
    getvar\ product|getvar\ version|getvar\ max-download-size|getvar\ secure|getvar\ unlocked\
    |getvar\ off-mode-charge|getvar\ battery-voltage|getvar\ battery-soc|getvar\ current-slot\
    |getvar\ has-slot:boot|getvar\ error_print|getvar\ devicemodel|getvar\ rescue_get_hwid\
    |getvar\ partition-type:*) return 0;;
    oem\ get_noboot_reason|oem\ get_bootFail_info|oem\ get_bootFail_ver|oem\ battery_present_check\
    |oem\ emmc_diag|oem\ get-lockstate|oem\ device\ info|oem\ get-build-number|oem\ get-product-model\
    |oem\ get-psid|oem\ get_socid|oem\ read_bsn|oem\ read_die_id|oem\ get_key_version\
    |oem\ get_hwnff_ver|oem\ get_current_slot|oem\ zzz_no_such_cmd_control) return 0;;
    *) return 1;;
  esac
}

run() { # run <描述> <完整命令字符串>
  local tag="$1"; shift
  local cmd="$*"
  if ! ALLOW "$cmd"; then echo "  [x] 白名单拒绝,未发送: $cmd"; return 9; fi
  local o
  o=$(timeout 25 $FB $cmd </dev/null 2>&1 | tr -d '\r\000')
  printf '%s\n' "$o" > "$OUT/$(echo "$tag" | tr ' /:' '___').txt"
  echo "--- $tag"
  if [ -z "$o" ]; then echo "    (空返回)"; else printf '%s\n' "$o" | sed 's/^/    /'; fi
}

if ! $FB devices 2>/dev/null | grep -q fastboot; then
  echo "[x] 现在总线上没有 fastboot。先短接测试点进 COM1.0,再跑 tools/pair_split.sh b186p"
  echo "[*] end $(date +%H:%M:%S) 未发送任何命令"
  exit 5
fi
echo "[=] 通道在: $($FB devices 2>/dev/null | tr -d '\r\000' | tr '\n' ' ')"

echo
echo "########## A. 对照组:一个确定不存在的命令 ##########"
echo "# 判据:若下面这条回 'unknown command'/'invalid command',而 B 组回别的内容,"
echo "#       就证明 B 组的命令名被 LK 认识了。若两者回一样的东西,则整组无效,不能下结论。"
run "control-unknown" oem zzz_no_such_cmd_control

echo
echo "########## B. 启动失败记录(最想要的) ##########"
run "noboot_reason"   oem get_noboot_reason
run "bootFail_info"   oem get_bootFail_info
run "bootFail_ver"    oem get_bootFail_ver

echo
echo "########## C. 电池 ##########"
run "battery_present" oem battery_present_check
run "gv-battery-voltage" getvar battery-voltage
run "gv-battery-soc"     getvar battery-soc
run "gv-off-mode-charge" getvar off-mode-charge

echo
echo "########## D. eMMC 健康 / 写保护 ##########"
run "emmc_diag"       oem emmc_diag

echo
echo "########## E. 锁状态 / 身份 / 版本 ##########"
run "lockstate"       oem get-lockstate
run "gv-secure"       getvar secure
run "gv-unlocked"     getvar unlocked
run "device-info"     oem device info
run "build-number"    oem get-build-number
run "product-model"   oem get-product-model
run "key_version"     oem get_key_version
run "hwnff_ver"       oem get_hwnff_ver
run "current_slot"    oem get_current_slot
run "socid"           oem get_socid

echo
echo "########## F. 分区容量(getvar 另一条分派路径,可能不是 stub) ##########"
for p in xloader ptable fastboot vrl vrl_backup boot system bootfail_info misc; do
  run "ptype-$p" getvar partition-type:$p
done
run "gv-product"  getvar product
run "gv-version"  getvar version
run "gv-maxdl"    getvar max-download-size
run "gv-errorprint" getvar error_print

echo
echo "[=] 命令名出处(可复核): rb186/fastboot.img 偏移"
echo "    0x181310 get_noboot_reason   0x1812a0 battery_present_check"
echo "    0x182bb0 oem emmc_diag       0x184e08 get-lockstate"
echo "    0x182c90 oem get_bootFail_info  0x1ceb30 'Boot fail @ BL1'"
echo "[*] end $(date +%H:%M:%S)  全程零写入  目录=$OUT"