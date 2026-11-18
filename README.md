# maimang6-rne-al00

华为 **麦芒6 RNE-AL00**（Kirin 659 / hi6250）刷机 / Root / 救砖 的工具脚本与完整经验记录。

**最终成果**：EMUI 8.0 B379 正常启动 · Magisk v31.1 root 已确证 · 广告类系统应用已精简 · 全程零身份分区写入。

> 本仓库是个人设备的研究记录，**不含固件本体**（版权 + GitHub 体积限制）。只放工具脚本、经验文档、小校验件和 vrl 修复镜像。

## 导航

| 路径 | 内容 |
|---|---|
| **[docs/EXPERIENCE.md](docs/EXPERIENCE.md)** | ⭐ 完整经验总结：引导链 / 固件验证 / 刷机通道 / vrl 根因 / EMUI8 全刷 / Root / 精简 / GSI 评估 / 救砖 / 方法论 |
| [docs/kirin_cheatsheet.md](docs/kirin_cheatsheet.md) | 麒麟 AOSP bring-up 参考（分区含义、EMUI5 vs 8 镜像拆分、解锁层级） |
| [docs/rne_firmware_db.json](docs/rne_firmware_db.json) | RNE-AL00 官方固件数据库记录（版本/字节数/日期，验收锚点） |
| [tools/](tools/) | 全部脚本：固件解析 / RAM 载入 / fastboot 刷入 / vrl 修复 / 反汇编 / 零写入读回 / GUI 自动化 |
| [scripts/](scripts/) | EMUI8 卡刷摆盘 / 探针 / 升级 / 回滚脚本 |
| [checksums/](checksums/) | 固件镜像 SHA256SUMS / dd_set manifest+plan / 官方包 md5 |
| [fix_vrl/](fix_vrl/) | vrl 防回滚证书修复镜像（还原源 + B186/EMUI8 纠正镜像，共 1MB） |

## 核心结论速览

- **不启动根因**：麒麟 `vrl` 防回滚证书仓库的槽位 =「镜像在活分区表里的序号 × 4096」。EMUI8 相对 EMUI5 **重排了 GPT**，换表后 vrl 必须按新表序重排，否则 xloader 安全校验失败 → 黑屏 / ERROR MODE Func 8。详见 [EXPERIENCE §5](docs/EXPERIENCE.md)。
- **可写通道**：盘里官方 LK 受限（只答 max-download-size）。短接进 **COM1.0** → `tools/pair_split.sh b186p` RAM 载入带 4096 前缀的 5.1 引导对 → UNLOCKED → `flash ptable` 热重载 → fastboot 可写。
- **EMUI8 Root**：分离式 boot 无 `boot` 分区，Magisk 修补 **`ramdisk.img`** → flash 到 `ramdisk` 分区。三重验证（写入 OKAY + 读回分区 sha 一致 + `su` uid=0）。
- **精简**：`pm uninstall -k --user 0` 卸广告应用，可恢复（`pm install-existing --user 0`），不动 /system，保留稳定组件。

## 快速开始（救砖 / 拿可写通道）

```bash
# 1. 冷启动短接进 COM1.0 下载口 (PID_3609 / COM3)
# 2. 两段式 RAM 载入带前缀的 5.1 引导对 (不写闪存)
bash tools/pair_split.sh b186p
# 3. 确认通道
fastboot getvar max-download-size      # 应答 471859200
fastboot oem device-info               # FB LockState: UNLOCKED
# 4. 翻表到 EMUI8 GPT (热重载, 幂等)
fastboot flash ptable dd_set/efi.img
# 5. 此后可 fastboot flash ... (每写必 readback sha 校验)
```

> 脚本里的 `dd_set/`、`emui8_b379/`、`rescue/`、`platform-tools/` 等路径指向**本地工作区的固件/工具**，本仓库不含这些大文件。需先用 `tools/huawei_firmware_extractor.py` 从官方包重建刷机组，并对照 `checksums/` 校验。

## 安全规则（务必遵守）

- **禁写分区**：`efuse`（一次性熔丝）、`oeminfo` / `frp` / `nvme` / `modemnvm_*` / `modem_om` / `modem_secure` / `secure_storage`（设备身份与校准）、`userdata`（清数据需单独批准）。
- **只刷内容级验证过的官方包**或手机自己的 stock 镜像；加密包 / 付费官改 / md5 自校验都不算来源验证。
- **每写必全分区读回 sha256 校验**，还原源始终在手；`Writing OKAY` ≠ 落盘。
- **物理回执 ≠ 写入批准**；屏幕是权威观测，总线空 ≠ 死。

## 环境

- Windows 10/11 x64 + Git Bash（`export MSYS_NO_PATHCONV=1` 防 adb 远程路径被篡改）
- Python 3.12（反汇编需 `capstone`；hisi-idt 需 `pyserial lxml`）
- platform-tools 1.0.41（adb/fastboot）；第三方深刷工具 rescue/（mrt、deepflash.ps1、hisi-idt、Potato.ImageFlasher）
- 设备：RNE-AL00，BL 已解锁（ORANGE，无解锁码），eMMC

## License

脚本与文档供学习研究使用。固件版权归华为所有，本仓库不分发固件。