# 麦芒6 RNE-AL00 刷机 / Root / 救砖 完整经验总结

> 设备：华为 麦芒6 **RNE-AL00**（Kirin 659 / hi6250，eMMC，arm64-v8a）
> 时间跨度：2026-11-15 → 2026-11-19
> 最终状态：**EMUI 8.0 B379 正常启动 + Magisk v31.1 root 已确证 + 广告类系统应用已精简**
> 本文所有技术结论均以**逐字节读回 / 反汇编 / 屏幕实物回执**为证据，不是推断。推断与实测会明确区分。

---

## 0. 一句话结论

这台手机从「官方 EMUI 5.1 B186 + 解锁 BL」出发，经历了 **TWRP+dd 手写 EMUI8 → 黑砖 → 整体回滚 B186 → 仍黑砖 → 定位 vrl 防回滚证书槽失配 → 官方 5.1 LK 通道分阶段 fastboot 刷 EMUI8 B379 → 修 vrl 槽位布局 → 正常启动 → Magisk 修补 ramdisk 拿 root → 精简广告应用** 的完整过程。

最大的技术收获是搞清了**麒麟引导链的 vrl（防回滚证书仓库）槽位语义 =「镜像在活分区表里的序号 × 4096」**，以及 **EMUI8 相对 EMUI5 重排了 GPT**，所以换表后 vrl 必须按新表序重排——这是贯穿全程「黑屏 / 无日志 / 短接可救 / ERROR MODE Func 8」所有现象的单一根因。

---

## 1. 设备与硬件真相

| 项目 | 真实值 | 备注 |
|---|---|---|
| 型号 | RNE-AL00（麦芒6，代号 Rhone / HWRNE） | oeminfo 身份串 `RNE-AL00C00B186`，从未被污染 |
| SoC | Kirin 659 / hi6250 | ARM64，eMMC（**不是 UFS**） |
| RAM / ROM | **4GB / 64GB** | 实测硬件无缩水 |
| 屏幕 | 1080×2160 | |
| 出厂系统 | EMUI 5.1 / Android 7.0 / C00B186 | kernel 4.1.18 |
| 现系统 | EMUI 8.0 / Android 8.0 / B379 | sdk 26，security_patch 2020-05-01，kernel 4.4 |
| BL 锁 | `ro.boot.flash.locked=0` / ORANGE / userlock=unlocked | 用户解锁，**无解锁码**（不能手动回锁） |
| Treble | **`ro.treble.enabled=true`**（EMUI8 实测） | EMUI5.1 上为空、无 VINTF manifest |
| baseband | 21C60B269S007C000 | modem NV 仍是 B186（禁写，未碰） |

### 1.1 「关于手机」里的伪装是官方显示层，不要为它动分区
设置页曾显示 **NEO-AL00 / 3GB / 32GB / 720p / Android 6.0 / EMUI 5.0** —— 这是官方 `ro.build.hide` 显示层伪装（product.img 自带），**硬件全正常**。`ro.*` 只读改不了，别为这个伪装去动任何分区。

### 1.2 侧键间歇性失灵 = 硬件排线接触不良
音量键 / 电源键时好时坏、跨版本一致。有界 `getevent` 证明**音量键真实触发 EV_KEY、设备注册全对** ⇒ 是**侧键排线（FPC）硬件接触不良**，不是软件 / DTB 问题。
**操作后果：别依赖按键进 fastboot / recovery**（三键强刷不可靠），救砖一律走 **COM1.0 短接**。

---

## 2. 麒麟引导链基础（理解一切的前提）

```
BootROM(片内, COM1.0 下载口)
   └─> xloader (BL2, ARM32 Thumb, 跑在 SRAM)   ← 校验 vrl 防回滚证书
          └─> LK / fastboot (BL3, ARM64, 0x10000000)  ← 逐镜像 sec verify, 画 ERROR MODE
                 └─> kernel + ramdisk / recovery
```

### 2.1 EMUI5 vs EMUI8 的镜像形态差异（关键）
- **EMUI5 及更早**：常规 `boot.img`（kernel+ramdisk）+ `recovery.img` / `recovery2.img`。
- **EMUI8 起**：拆成 **`kernel`**（带 4096B 华为前缀，boot-header 在 0x1000，kernel_size 真实）+ **`ramdisk`**（`ANDROID!`@0，kernel_size=0，纯 ramdisk）+ `recovery_ramdisk` / `recovery_vendor` / `erecovery_*`。**没有 `boot` 分区**。
- 因此 **EMUI8 上 root 的目标是 `ramdisk.img`，不是 boot.img**；已验证的 EMUI5.1 TWRP 在 EMUI8 上失效（`boot`/`recovery` 分区名都不存在了）。

### 2.2 4096 字节签名前缀约定（最容易踩的坑）
- **送进 RAM 下载（COM1.0）的镜像必须带 4096B 前缀**；剥了前缀的 xloader 送进去**每帧都 ACK 0xAA 但 BootROM 不执行**，设备仍停在 BootROM 下载口，下一张 LK 头帧必被 NAK（`ACK=07`）。
- **写进 `fastboot` 分区的却是纯 LK（无前缀）**；写进 `xloader`（boot0）的却**带前缀**。
- 即「RAM 下载带前缀」与「fastboot 分区不带前缀」两件事同时成立，不矛盾。xloader 头与 fastboot 头有 1408B 不同（镜像专属，不能互换 / 伪造）。
- 实证：`emui8_b379/xloader.img[4096:] == rb379/xloader_pure.img`；`rollback_b186/xloader.img`(69184B) = 4096 头 + 65088B，正是 boot0 上的字节。

### 2.3 vrl 防回滚证书仓库（本项目核心）
- `vrl` / `vrl_backup` 各 256KB，**前 16KB 全零**，之后是**每镜像一个 4096B 签名头**的仓库，4KB 对齐。
- **由 xloader 校验**（不是 BootROM）：字符串 `RdVrl fail` / `ChkVrlErr` / `sec verify err … vrladdr … imgaddr` 都在 xloader 里。
- 块格式：`+0x80` magic=`0xe291f358`、`+0x08` write flg=1、`+0x0c` boot flg=1。**无整分区校验和**，xloader 只校验传进去的那一个 4096B 块。
- **槽位偏移 =「镜像在活分区表里的序号 × 4096」**（详见 §5）。

---

## 3. 固件来源与验证（刷机的第一道门）

### 3.1 唯一能刷的东西 = 内容级验证过的官方包
本项目最终验收了两个官方包：
- **B186（EMUI5.1）**：`RNE-AL00C00B186_Firmware_Android 7.0_EMUI5.1_05014PQM.rar` → `SDupdate_Package.tar.gz` → `UPDATE.APP`(4,165,383,612B)。
- **B379（EMUI8.0）**：`Rhone-AL00_8.0.0.379(C00)_Firmware_EMUI8.0_05014YML.zip`(7,089,155,771B) → `UPDATE.APP`(4,055,692,392B)。

验收锚点（缺一不可）：
1. 包内自签名 `curver` 串精确匹配机型（`RNE-AL00C00B186` / `Rhone-AL00 8.0.0.379(C00)`，Rhone=RNE 代号）。
2. `package_type=OFFLINE_UPDATE`，region 目录 `RNE-AL00_all_cn`。
3. payload **压缩（熵≈6.2）而非加密**；大分区是标准 **sparse-ext4**（头 `3aff26ed`）。
4. 官方固件数据库 `rne.json` 有对应记录且字节数吻合（B379 记录 3,562,983,377B，包内两 update_sd.zip 之和差 0.031%）。
5. 镜像表里**没有 nvme/oeminfo 条目**（身份分区不在可刷集）。
6. 抽 `system.img` 读 `ro.treble.enabled=true` + `vendor.img` 读 VINTF manifest（GSI 前置）。

### 3.2 红旗（一律不刷）
- **加密卡刷包**：`MaiMang6_EMUI8.0_8.0.0.351.zip` md5 自校验 OK 但 updater-script 是 Stored 却高熵乱码、.dat 压缩率 1% ⇒ 整包加密不可读 = 不可验证 = 不刷。**md5 自校验只证明下载没坏，不证明来源。**
- **付费官改 / 一键 Root 包**（奇兔 7to / ONFIX ¥19 等）：内容不可验证，同加密包一类，拒绝。
- **TDS 直链全 404**：`update.dbankcdn.com/TDS/...` 对本机 42 个 RNE 路径全 404，官方历史目录已清。
- **官方下载接口 PC 用不了**：`query.hicloud.com/sp_ard_common/...` 需设备证书+签名，只认手机 eRecovery/HiSuite/售后盒子，**不伪造设备签名**。

### 3.3 华为 sparse 1.0 的两个反直觉点
- chunk header 12B 三个 u32：type@0 / count@4 / **size@8（含 header）**；**`0xCAC1`=data / `0xCAC3`=hole**（和现代 AOSP 相反）。
- ext4 magic 判定要用 **16 位** `(u32(0x438)&0xffff)==0xEF53`（s_pad 高位是 0x0001，写 32 位全等会误判）。

---

## 4. 刷机通道（怎么把字节真正写进闪存）

### 4.1 官方 LK 的「可写分区白名单」
- 盘里 `fastboot` 分区 = **EMUI8 官方受限 LK**（`emui8_stage/fastboot_full4m.img` 4194304B = `dd_set/fastboot.img` 2864640B + 零填充）。
- 它**只答 `getvar max-download-size → 471859200`**，其余 getvar / flash / erase 全 `Command not allowed`。
- 白名单逻辑：**名字不在白名单就一律 Command not allowed**（对照组 `flash xyzzy_not_exist` 报完全相同错）。`Warning: partition size: 0` 也是未知名字的表征，不代表特殊分区。
- ⇒ **`adb reboot bootloader` 进的是这个受限 LK，不可写。**

### 4.2 COM1.0 深刷的能力边界（已定案）
- 短接进 **COM1.0 下载口**（PID_3609 / COM3）。整个 VCom 协议 = start frame `FE 00 FF 01 …`（重传直到 0xAA）+ head `FE 00 FF 01 | len BE | addr BE` + `DA n ~n` 数据 + `ED n ~n` 尾，CRC16-ccitt。
- **协议里没有「写闪存」指令**。`bootloaderimage` 地址全是 RAM（xloader@0x00020000，LK@0x10000000）。分区之所以能被写，是因为 **RAM 载入的 LK 随后答 fastboot**，写盘走的是 fastboot。
- ⇒ IDT / hisi-idt / Potato.ImageFlasher 的片内串口模式**没有超出 `deepflash.ps1` 的能力**。官方 IDT 的 PASS 日志价值在于它给出了**权威写盘顺序**（见 §4.5）。

### 4.3 可写通道 = 短接 → RAM 载入工程/官方 5.1 LK
标准救砖 / 写入动作：
```
冷启动短接 → COM1.0(PID_3609/COM3)
   → tools/pair_split.sh b186p   # 两段式 RAM 载入 rollback_b186 xloader+LK(带前缀)
   → FB LockState: UNLOCKED       # RAM 载入路径强制 fb_lock_stat=1
   → fastboot flash ...           # 此时可写
```
- **两段式**（`pair_split.sh`）比单计划两镜像可靠：session1 只送 xloader → 等下载口返回 → session2 只送 LK。单计划模式会在第二张首帧卡死（传输故障，非结果）。
- `b186p` = 带前缀的官方 5.1 对：`rollback_b186/xloader.img`(69184B) + `rollback_b186/fastboot.img`(2707072B)。
- `emu8p` = 带前缀的官方 EMUI8 对（`emui8_b379/xloader.img`+`fastboot.img`），RAM 载入后能跑官方 LK 点亮屏幕，但**它认为设备锁着、不可写**（用新布局读 5.1 解锁标志读成 locked）⇒ 写入要用 **b186p**。

### 4.4 ptable 热重载（翻表的关键技巧）
- **新 RAM 载入的 b186p LK 默认带 B186 表**（system@40000000、boot@1b000000、无 kernel/ramdisk），即使 eMMC GPT 已是 EMUI8。
- 必须 `fastboot flash ptable dd_set/efi.img`(17408B, sha `9cbb0b59…`) 触发**热重载**：运行中的 RAM LK 立即重读表，`getvar storage:kernel` 马上回 `1b800000`，**无需 reboot / 二次短接**。
- 翻表后：kernel@1b800000 / system@4d800000 / ramdisk@1d000000。
- `ptable` 是**可写名字**（推翻早期「白名单写不了表」结论）；`efi.img` 幂等（与盘里 EMUI8 GPT 同一份）。

### 4.5 官方 IDT PASS 日志的权威写盘顺序
`IDTLog/USB1/PASS_2018-09-30_14.15.35.log` 开头握手 `OKAY471859200`（与本机实测同值，证明同一模式）：
```
huawei_crc_check → xloader(69KB,带前缀) → ptable(17KB) → fastboot → dts
→ fw_lpm3 → sensorhub → fw_hifi → cache → nvme → trustfirmware → modem_fw
→ modemnvm_update → modem_om → modemnvm_img → userdata → system → vendor
→ product → version → splash2 → frp → oeminfo → secure_storage → modem_secure
→ kernel → ramdisk → recovery_ramdisk → recovery_vendor → vbmeta → odm
→ efuse(0KB) → Rebooting
```
- **每写一个分区跟一次 `huawei_crc_check`** = 官方确认「真落盘」的校验步骤（payload 0~297KB，构造方式未知，无法复现）。
- 官方 `writing 'dts'`(24MB) 花 2s、`system`(1.39GB) 花 42s ⇒ **真落盘耗时与尺寸线性**；工程 LK 那种 131MB `0.000s` 可疑。
- **`xloader`/`ptable` 在此模式可写**（虽不在 GPT 里）。`system` 超 450MB 上限会自动分块（sparse 镜像 AOSP fastboot 自动切）。

### 4.6 主机侧 fastboot.exe 的坑（多次踩到）
1. **新连接丢首包**：LK 在新 USB 连接上丢第一个 getvar 包。`fbraw.py` 有重问所以能过；`fastboot.exe` 不重问 ⇒ 永久等待 ⇒ **空输出**。判别：空输出先查耗时是否正好等于 timeout（如 121s=timeout 120 杀的），再怀疑设备。**加固：任何 flash 前先跑只读 `getvar max-download-size` 预检（带重试），答出 471859200 才写。**
2. **管道间歇吞输出**：`fastboot.exe … | tr` 有时吞掉全部输出；重定向到文件则正常。判别 = 重定向到文件再读。
3. **`upload_storage` 的 addr 是绝对字节地址**，不是分区内偏移：vrl 起始 0x80000 + 槽内 0x6000 = **0x86000**。读回框架两种都见过（`data+OKAY` / `OKAY+data+OKAY`），剥法按实际首尾判，不能硬编码。
4. **`upload_memory` 走 USB DMA 不是 CPU memcpy**：外设窗口地址（如 chipid 的 MMU VA 0xfff0ae00）DMA 到不了会 ReadPipe err=31 但 LK 不挂；RAM 段（VA==PA）正常。

---

## 5. 不启动根因定案（vrl 证书槽失配）

### 5.1 现象与排除
刷 EMUI8 后黑屏 / 无 bootfail 日志 / 自主启动连 COM1.0 都不出现，但**短接能进 COM1.0、RAM 载入能跑**。逐字节读回排除了一切早期假设（表代际、906KB 空隙、镜像前缀、电池、eMMC 写保护）：
- 整条 B186 引导链在闪存上**逐字节正确**（xloader/fastboot/fw_lpm3/teeos/…全 IDENTICAL）。
- 活 GPT 完好。
- **唯独 `vrl@0x6000` 逐字节等于 EMUI8 LK 的 4096B 头，而盘里 LK 是 B186** ⇒ 证书与本体失配。

### 5.2 为什么这一条解释全部现象
- 黑屏：xloader 在 sec verify 失败处停住，**还没到 LK，屏幕不亮**。
- bootfail_info 全零：失败在 xloader 早期，不写 LK 日志分区。
- 短接可救：下载模式绕过闪存 VRL 校验。
- 手机温的：SoC 上电跑过 xloader，不是没供电。

### 5.3 代码级证明（纯离线零写入）
工具 `tools/xldis.py`（ARM32 Thumb 反汇编）+ `tools/lkdis.py`（ARM64）：
- xloader `0x224` 读 vrl **偏移 0x6000 长度 0x1000**（从 callee `0xc28` 的算术证明：分区起始 KB×1024 + 偏移）。
- 失配**致命**：`return -1` → `FsLdCk fail!` bootfail **0xa2**；secverify 失败 → **0xa3**。
- **无整分区校验和**：`0x5dc0 vrl_validate` 只校验传入的那一个块。
- chipid 跳过分支只针对仿真器：`0x62502000`=EMU、`0x62501000`=FPGA（LK 自己的日志串 `This is FPGA!`/`[EMU_FASTBOOT]This is EMU!`），真硅 `0x62500100` ⇒ 实体机必然执行 vrl 读。
- **LK 为何不自己刷新 vrl**：`write_vrl`@0x1d9720 有静默门槛 `*(u32*)*(ptr*)0x294218 == 1`；实测 `*(u64*)0x294218=0x30693d00`、`*(u32*)0x30693d00=0` ⇒ 静默 return 0，不写不打日志。判别对照：0x30693c00 读回 512B 真实非零堆数据 ⇒ 那些零是真零不是读失败。

### 5.4 真正根因：槽位 = 活表序号 × 4096，EMUI8 重排了 GPT
前两次 vrl 修复（主份+backup 换 EMUI8 证书）都无效，因为**证书放错了槽位**。
- EMUI8 LK `SecBoot_GetVrlOffset`@0x1285e0：拿序号 → `lsl w1,w0,#0xc`（**序号×4096**）。
- 名字→序号@0xa6ddc：遍历分区数组（stride 0x40），数组 = `[xloader, ptable] + GPT 各项` ⇒ **vrl 槽 = (GPT 序号 + 2) × 4096**。
- B186 GPT 反验 8/8 全吻合（fw_hifi GPT26→0x1c000 等）。
- **EMUI8 GPT 重排**：fw_hifi GPT25→LK27→**0x1b000**（B186 是 0x1c000）。旧布局把 sensorhub 证书放在 0x1b000 ⇒ EMUI8 LK 校验 hifi 去 0x1b000 取到 sensorhub 证书 ⇒ 哈希对不上 ⇒ **ERROR MODE Func 8 (hifi) security verify failed**。
- 证书↔本体自洽已坐实：证书 hash@槽内0x74c = sha256(精确包体长度)，扇区填充零无害。

### 5.5 修复历程（4 次 vrl 禁写例外，每次用户批准 + 全分区读回校验）
| 次 | 镜像 | sha256 | 改动 | 结果 |
|---|---|---|---|---|
| 1 | `vrl_b186cert.img` | `41be06b9…` | 289B/0x6000 换 B186 LK 证书 | B186 能 boot（进 eRecovery→低格 data→进 B186） |
| 2 | `vrl_emui8certs.img` | `4c08ca68…` | 3699B/11 槽换 EMUI8 证书（**按 B186 老偏移**） | 无效，Func 8 |
| 3 | 同上写 vrl_backup | `4c08ca68…` | powerup 校验走 backup | 仍 Func 8（槽位错） |
| 4 | **`vrl_emui8_layout.img`** | **`80416b0c…`** | 13 真证书**按 EMUI8 新槽位** | **Func 8 消失 → eRecovery → 重启直接进系统** |

- 第 4 次是关键：`tools/make_vrl_emui8_layout.py` 全 256KB 清零后把 13 个 EMUI8 真证书[:4096] 放到各自 EMUI8 槽（0x4000 fw_lpm3 / 0x6000 fastboot / 0x18000 teeos / 0x19000 trustfirmware / 0x1a000 sensorhub / **0x1b000 fw_hifi** / 0x1c000 erecovery_kernel / 0x1f000 kernel / 0x23000 dts / 0x25000 modem_fw / 0x26000 recovery_vbmeta / 0x27000 erecovery_vbmeta / 0x2a000 vbmeta）。**不伪造签名**，源=已验收包头。
- ramdisk/recovery_ramdisk/system/vendor/product/odm 等包头 magic=0（走 vbmeta/AVB，不入 vrl）；xloader 无 GPT 槽（BootROM 管，不入 vrl）。
- **核心教训：任何换表（GPT）后，vrl 必须按新表序重排，不能沿用旧槽位。**

---

## 6. EMUI8 B379 全刷全过程

### 6.1 走过的弯路
1. **TWRP+dd 手写**（11-15）：`build_dd_set.js` 把 36 张镜像 un-sparse 按 EMUI8 GPT 解析 LBA，TWRP 里 dd 写 27 分区 + 翻表。首启失败。
2. **整体回滚 B186**（11-16）：`restore_b186.sh` 逐文件 sha 门 + RAM 5.1 LK。仍黑砖。
3. 定位到**自己造成的损伤**：19:38 写进 fastboot 分区的 `emui8_b379/fastboot.img` 带 4096 前缀（开头全零），xloader 跳到 0x10000000 执行到头部字节 ⇒ 那个 LK 从未执行过。正确文件 = `dd_set/fastboot.img`（代码在偏移 0）。
4. 发现 **RAM 载入必须带前缀**（§2.2），`pair_split.sh emu8p` 一次成功点亮 fastboot 画面。

### 6.2 最终成功路线：官方 5.1 LK 通道分阶段 fastboot（任务 #29）
`tools/flash_emui8.sh`，料过闸（dd_set 31 件尺寸全对、小件 sha 全 OK）：
- **S1 翻表**：`flash ptable dd_set/efi.img` → 热重载（§4.4）。
- **S2 引导链 20 条**：xloader/fw_lpm3/fastboot/teeos/trustfirmware/sensorhub/fw_hifi/dts/vbmeta/recovery_vbmeta/erecovery_*/recovery_ramdisk/recovery_vendor/kernel/ramdisk…（含 vrl 例外）。
- **S3 大分区 9 条**：system（sparse 6 块 97.8s）/vendor（22.7s）/product/odm/cust/version/preas/preavs，写前全量 sha。
- **S4**：`erase misc` + `reboot`（**userdata 不碰，清数据需另批**）。
- 首启 ERROR MODE Func 8 → 修 vrl 布局（§5.5 第 4 次）→ eRecovery → 重启直接进系统，**未抹数据**。

### 6.3 每写必验
每条 `Writing OKAY` 后**整段读回 sha256** 比对目标镜像；耗时与尺寸线性才算真落盘；还原源始终在手。

---

## 7. Root（EMUI8 分离式 boot）

### 7.1 目标 = ramdisk.img
EMUI8 无 boot 分区。`dd_set/ramdisk.img` 是 `ANDROID!` boot-image，**kernel_size=0**（纯 ramdisk），16,777,216B，sha `6a4f2735…`。Magisk v31.1「安装 → 修补固件/镜像」修补其中的 ramdisk.cpio；**保留 AVB 2.0/dm-verity = 不勾**（KEEPVERITY=false），让修补后的 ramdisk 在解锁设备上能 boot。

### 7.2 存储权限坑（两次踩到）
首次修补显示「安装-失败」，但日志证明修补本身成功（`Stock boot image detected … Repacking boot image … new-boot.img`），只是最后拷贝失败：`! Failed to output to /storage/emulated/0/Download/…`。原因 = Magisk 缺存储权限。授予「始终允许」→ 重跑 → 「安装-完成」。**读日志用控制台「保存日志」按钮（存到 Download），logcat 只有 WindowManager 噪声。**

### 7.3 GUI 自动化（adb 驱动 Magisk 界面）
`adb shell uiautomator dump /sdcard/ui.xml` → pull → 解析 node bounds → `adb shell input tap X Y`（屏幕 1080×2160）。流程：安装(864,644) → 修补固件/镜像 → 从存储选择 → SAF 选择器 显示根目录(84,144) → 下载内容 → ramdisk.img → 确定。
- **Git Bash 会篡改 adb 远程路径**（`/sdcard/…` → `C:/Program Files/Git/sdcard/…`）⇒ 先 `export MSYS_NO_PATHCONV=1`。
- EMUI8 `adb install` 需屏幕「安装」确认（PackageInstallerActivity）。
- EMUI8 的 SAF「下载内容」视图**能**看到 adb push 的文件（与 B186 的 MediaStore 限制不同）。

### 7.4 刷入与三重验证（2026-11-19 00:24）
修补镜像 `out_check/magisk_patched-31100_T0fcO.img`，16,777,216B，sha **`10728810…6558d0`**。
通道：短接 COM1.0 → `pair_split.sh b186p` → UNLOCKED → **ptable 翻表**（新 RAM LK 默认 B186 表）→ `flash ramdisk`。
- `tools/root_ramdisk_stageA.sh`：等 COM1.0 → RAM b186p → 验 UNLOCKED + 镜像门（**无写入**）。
- `tools/root_ramdisk_stageB.sh`：ptable 翻表 → 验 EMUI8 表 → flash ramdisk → reboot → 有界观察。
- ptable Writing OKAY 0.016s → 热重载确证；ramdisk Writing OKAY **0.079s**（真写，非 0.000s ACK）；reboot → **20s 进 EMUI8**。

**三重证据：**
1. 写入 OKAY（耗时合理）。
2. **读回分区 sha256 == 修补镜像**：`su -c 'dd if=/dev/block/bootdevice/by-name/ramdisk bs=1M count=16 | sha256sum'` → `10728810…`，逐字节相同。ramdisk 块设备 = `/dev/block/mmcblk0p31`，by-name 路径是 `/dev/block/bootdevice/by-name/ramdisk`（**不是** `/dev/block/by-name/`）。
3. **运行系统**：`su -c id` → `uid=0(root) context=u:r:magisk:s0`；`magisk -v` → `31.1:MAGISK:R`；`magisk -V` → 31100。

### 7.5 USB 调试怪癖
**EMUI8 一拔数据线就自动关 USB 调试**。每次重连需重新开 USB 调试 + 传输文件/MTP 模式 + 「允许 USB 调试」RSA 授权。adb 接口 = USB SUBCLASS_42&PROT_01；PID_107E = 系统 MTP 复合口（调试关时无 adb 接口）。

### 7.6 去 root 回滚
重刷 `dd_set/ramdisk.img`（stock `6a4f2735…`）→ 无 root。

---

## 8. 精简广告类系统应用（2026-11-19）

方法：root `pm uninstall -k --user 0 <包名>` —— 只对当前用户卸载，APK 仍在 /system，**可恢复、不动系统分区**，比 rm 系统文件安全。

**已卸 15 个（A 组，广告/推广/推荐）：**
华为视频 himovie / 主题 thememanager / 音乐 mediacenter / 商城 vmall.client / 生活 lives / 服务 phoneservice / 玩机技巧 android.tips / 智能建议 huawei.tips / 文件夹推荐 hifolder / 推荐系统 recsys / 内容感知 contentsensor / 决策引擎 decision / 用户体验 bd / 即时在线 instantonline / 智慧助手 intelligent（负一屏）。

**保留稳定关键组件（C 组，绝不卸）：**
桌面 launcher / systemui / settings / 电话 phone+telecom+incallui / 短信 mms / 联系人 contacts / 图库 gallery3d / 相机 / 时钟 / 日历 / 文件 documentsui / 百度输入法 / 华为账号 hwid / 电源 powergenie / 资源调度 iaware / 系统服务 systemserver / 安全 securitymgr / **手机管家 systemmanager**（深度集成，管权限/电池）/ 服务框架 hsf / 通话记录 chr / 应用保护 hwaps / 全部 providers.* / framework / webview / packageinstaller / 蓝牙/NFC/指纹。

**B 组可选（云空间/网盘/支付/查找手机/克隆/语音助手/附近/智慧视觉/推送/系统更新/天气）全保留。**

注：本 B379 固件**没有**浏览器（com.huawei.browser）和应用商店（com.huawei.appmarket），`pm path` 全空，无需处理。

**恢复任一应用：** `su -c 'pm install-existing --user 0 <包名>'`。
验证：15 个全 Success 且从用户 0 消失；稳定组件全在；`sys.boot_completed=1`，root 仍 uid=0。

---

## 9. GSI / 更高安卓评估与放弃

- **Treble 实测成立**（EMUI8 `ro.treble.enabled=true` + vendor manifest）⇒ GSI 前置满足。
- **EMUI8 非 SAR** ⇒ 最高 **Android 11 GSI（arm64 A-only）**；EMUI9 SAR 才能 13/14（但 RNE 无可验证免费 EMUI9 包）。
- hi6250 有专用修复版 GSI（XDA ExpressLuke / Telegram hi6250releases，Android 11 fixed v2.2）；同麒麟 659 机型（荣耀 6x/9 Lite）已实测安卓 11 启动。刷法 = `fastboot flash system <GSI>` → 官方 rec 恢复出厂 → 重启。
- **就绪审计**：工具/EMUI8 地基（36 件 sha 全校验）/回滚 kit/Magisk apk 齐全；**唯一硬缺口 = 没有 GSI 镜像本身**（修复版源被挡：Telegram 超时 / XDA 403）。modem NV 仍 B186（禁写）→ GSI 射频待验证；system≈3.5GB，安卓 11 GSI 可能需扩容。
- **用户评估收益后决定「到此为止吧」** ⇒ GSI 路线放弃，转 root + 收尾。

---

## 10. 回滚与救砖 kit

| 目标 | 动作 |
|---|---|
| 救黑砖（任何状态） | 冷启动短接 → COM1.0 → `tools/pair_split.sh b186p` → fastboot 可写 |
| 回滚整个 B186 | `rollback_b186/`（带前缀完整件）+ `tools/restore_full_b186.sh`（17 条 sha 门）；vrl 两份用 `vrl_b186cert.img`(41be06b9) 还原 |
| 还原 vrl 现状 | `fix_vrl/vrl_original.img`(4988f479) / `vrl_emui8certs.img`(4c08ca68) 在手 |
| 去 root | 重刷 `dd_set/ramdisk.img`(6a4f2735) |
| 还原 GPT | `fastboot flash efi backups/gpt_primary_current.img`（现表已备份 17408B） |

**禁写分区（绝不碰）：** `efuse`（一次性熔丝，可能永久锁死/防回滚）、`oeminfo`/`frp`/`nvme`/`modemnvm_*`/`modem_om`/`modem_secure`/`secure_storage`（设备身份与校准）、`userdata`（清数据需单独批准）。modem NV 用户明确**不碰**。

---

## 11. 工具清单（tools/）

| 脚本 | 用途 |
|---|---|
| `huawei_firmware_extractor.py` | 解析 UPDATE.APP，抽镜像 + 读 curver/verlist/build.prop（验收核心） |
| `pair_split.sh` | 两段式 RAM 载入（b186p/emu8p/tool/toola），救砖拿可写通道 |
| `flash_emui8.sh` | EMUI8 分阶段 fastboot 刷入（s1 翻表/s2 引导链/s3 大分区/s4 清 misc） |
| `root_ramdisk_stageA.sh` / `stageB.sh` | root：A 拿通道+验镜像（无写）；B 翻表+flash ramdisk+reboot |
| `fix_vrl_cert.sh` / `fix_vrl_layout.sh` | vrl 修复（带只读预检门 + 还原源 sha 门 + 写后读回） |
| `make_vrl_emui8.py` / `make_vrl_emui8_layout.py` | 离线造 vrl 纠正镜像（按 EMUI8 槽位，不伪造） |
| `fbraw.py` | 裸 WinUSB fastboot 客户端，硬白名单，收 DATA 即中止（构造上零写入读回） |
| `readback_cmp.py` | 读回镜像 vs 目标逐字节比对 |
| `xldis.py` / `lkdis.py` | xloader(Thumb) / LK(ARM64) 反汇编 + 字符串引用 |
| `winusb_probe.py` | 主机侧 WinUSB 可用性验证（不需改驱动） |
| `build_dd_set.js` / `simg2img.js` | un-sparse + 按 GPT 解析 LBA 造 dd 刷机组 |
| `gpt_parse.js` / `gpt_check.js` / `gpt_fix.js` | GPT 解析/CRC 校验/补全 |
| `parse_boot.js` / `boot_hdr.js` / `hdr_dump.js` | boot image 头解析 |
| `utap.js` | adb uiautomator dump + 按文本/坐标点击（GUI 自动化） |
| `phone_ids.ps1` / `pnp_now.ps1` / `bus_deep.ps1` | USB 总线枚举（PresentOnly，排幽灵设备） |
| `oem_diag.sh` | 只读 oem 诊断（noboot_reason/锁状态/电池/oeminfo） |
| `restore_full_b186.sh` / `restore8.sh` | 回滚 B186 / 补 EMUI8 引导集 |
| `gf.bat` | Firmware Grabber（固件数据库抓取） |

第三方工具（**不在本仓库**，需自备）：`rescue/`（mrt fastboot/adb、deepflash.ps1、hisi-idt、Potato.ImageFlasher）、`platform-tools/`（adb/fastboot 1.0.41）、IDT_V2.0.0.9、gusb。

---

## 12. 方法论与踩坑总结（最值钱的部分）

1. **屏幕是权威观测，总线空 ≠ 死。** ERROR MODE 循环时总线全空但屏亮；off-bus ≠ dead。优先用户屏幕实物回执，而非端口日志推断。
2. **物理回执 ≠ 写入批准。** 「连上了」「出 fastboot 了」只算物理步骤回执，不算写入批准。每个写入都要单独点头。
3. **每写必全分区读回 sha 校验 + 还原源在手。** `Writing OKAY` 不等于落盘（工程 LK 可能只 ACK）；耗时与尺寸线性 + 读回逐字节相同才算数。
4. **探针必须有判别力。** 对照实验救场：判「字符串 0 引用」前先扫邻近同族字符串；判「读回全零」前先读邻近已知非零地址证明 DMA 可达。
5. **先查自己的日志再怀疑用户的手。** 多次「不启动」是自己写错文件（带前缀的 LK 写进 fastboot 分区）造成的。
6. **字符串引用扫全镜像，再按函数结构判真伪。** 限定范围扫会漏真引用（0x1d9720 起有完整真代码）；正则必须含 `\n`（日志串多以 `\n\0` 结尾）；Thumb 引用 = MOVW/MOVT 对或 LDR-literal+ADD Rd,PC；表引用先试绝对 8B 指针再试 ADRP。
7. **USB 在/不在只有在线缆状态已知时才有判别力。** Win32_PnPEntity 含幽灵设备（桌上另一台华为 CPE 的 PID_108A 曾误判）；用 `Get-PnpDevice -PresentOnly` + LastArrivalDate + 端口/序列号。
8. **判只读必须用代码引用 + 函数边界，字符串相邻 ≠ 同函数。** `oem get_bootFail_info` 的 DUMPSTART 与 storage_write 同函数 ⇒ 不是纯读，已撤白名单。
9. **fastboot 空输出先查耗时是否=timeout，再怀疑设备。** 新连接丢首包 / 管道吞输出都是主机侧坑，加只读预检门 + 重定向到文件。
10. **换表后 vrl 必须按新表序重排。** 这是贯穿全程的单一根因。
11. **不刷不可验证的固件。** 加密包/付费官改/md5 自校验都不算来源验证；只刷内容级验收过的官方包或手机自己的 stock 镜像。
12. **长等待用后台+通知，不用阻塞 sleep。** 有界观察（前 60s 不下结论），屏幕为准。

---

## 13. 仓库内容说明

**本仓库只含**：工具脚本（tools/、scripts/）+ 经验文档（docs/）+ 小校验件（checksums/）+ vrl 修复镜像（fix_vrl/，1MB）。

**不含**（GitHub 100MB 上限 + 版权）：多 GB 官方固件包、解包镜像（dd_set/emui8_b379/fw_b379/fw_b186/rollback_b186/rb186/stock_b186*）、第三方工具二进制（rescue/platform-tools/IDT/gusb）、手机数据备份、日志证据。这些留在本地工作区 `C:/Users/64563/Desktop/maimang6/`。

`checksums/` 里的 SHA256SUMS/manifest 记录了所有固件镜像的哈希与 LBA，配合 `tools/huawei_firmware_extractor.py` 可从官方包重建刷机组。`fix_vrl/` 的 4 张 vrl 镜像是本项目唯一需要长期保留的小二进制（还原源 + 纠正镜像）。

> ⚠️ 刷机有风险，本文是个人设备的研究记录。任何写入前务必：验证固件来源、备份数据、确认禁写分区、每写读回校验、保留还原源。身份分区（nvme/oeminfo/modemnvm_*）与 efuse 绝不写。