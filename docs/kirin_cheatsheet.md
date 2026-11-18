# Kirin AOSP helper
A helpful cheat sheet for people interested in Huawei Kirin AOSP development  
  
NOTE: This thing is pretty much EOL from my side, so feel free to fork and continue if you want to.  
- [Important things to know](#important-things-to-know)
- [The Partition table](#the-partition-table)
- [Basic bringup](#basic-bringup)

## Important things to know
* You have to be aware of that all EMUI versions are pretty different in almost all things (kernel, blobs, partition table, dtbs, etc.). Huawei OTAs are also resizing the ptable, so because of that, for example, **all** EMUI 8 devices (launched or upgraded) got Treble support (In fact EMUI 5 had a vendor partition already but that was smaller than on EMUI 8). 
* Huawei likes to "backport" features which aren't even existing on AOSP yet, there are alot of good examples: vendor partition on EMUI 5 (on AOSP since Android 8.0), odm partition on EMUI 8/9 (on AOSP since Android 10), AVB2 with vbmeta partitions (disabled until EMUI 10) on EMUI 8 (on AOSP since Android 9), (pretty unrelated to development but why not) fullscreen gestures on EMUI 8.2(?) and 9.x (on AOSP since Android 10) and way way more things.
* Try to get the latest and most fully functional (!!!) kernel source you can get for your platform, here are some examples: Hi6250 EMUI 5.0: Prague, Hi6250 EMUI 5.1: RNE (RNE has broken tzdriver, port from PRA-5; BND one has broken OMX for some reason), Hi6250 EMUI 8: AGS2 (working calls on recent PRA/WAS firmware with jan 2021 secpatch; broken wifi drivers, port from FIGO-8 or LELAND-8), Hi6250 EMUI 9: AGS2 HarmonyOS 2.0.0 (from November 2021, working fine with ANNE's 9.1.0.401 firmware, aka. Jan 2022 secpatch).
* Unfortunately, we can't reproduce the DTS.img yet, which has the DTBs. This means, we can't change stuff in the kernel device tree, which might be pretty pain in some cases, for example we need hacks like [this](https://github.com/hi6250-oss/android_kernel_huawei_hi6250-9/commit/39dfd63b2fa5280357866f097da622f3cb494905) to kill the device tree fstab which is fucked up anyways, specially on EMUI 8. For more infos about DTS.img, I will do a research repository, which I will link here once it's done.
* Huawei is known to update the kernel version with new Android releases (EMUI 4 uses 3.10, EMUI 5 4.1, EMUI 8 4.4, EMUI 9 4.9, EMUI 10 and newer 4.14). Just slapping EMUI x kernel on EMUI y doesn't work sadly, this requires to use their blobs, and most important, you need the EMUI x's dtbs, meanwhile you can't use EMUI x's DTS.img on EMUI y due to a "different format" (the bootloader rejects it), reproducing DTS.img isn't an option yet, or if you are "pro enough" and you have alot of time to waste and you want to go through the pain, you can either adapt the complaining drivers for EMUI y's dtbs, or the port EMUI y's drivers to EMUI x's kernel. But thats only for big pros, I would say. 
* If you need kernel logs because your kernel doesn't work then you only have 1 option: pstore. Pstore is already enabled in the kernel and you will always get one as long as the kernel actually works. Last_kmsg doesn't exist (qcom noises). Sometimes, there might be useful logs in /splash2 partition for alot of things. If that isn't enough, and you need bootloader logs, you can check `/proc/balong/log`. It gives you the current and last bootloader log.
* Good to know about the fastboot mode, there are 2 types of unlock. User unlock which you can unlock using `fastboot oem unlock 1234567890ABCDEF`, it always you flash some basic partitions + unsigned images (non stock). Then theres factory unlock / fblock, (only applies to devices older than EMUI 8.x, sometimes EMUI 9.x too) which can be triggered by `fastboot oem hwdog certify set 0` on fully unlocked board firmware fastboots, or also using the nvme tool by @R0rt1z2. The unlock "flag" is basically in the nvme partition. As the name tells you already, It allows you to do **everything** in fastboot.

## The Partition table
Now we gonna look at some huawei partitions. First important side note
* EMUI 5 and older uses regular boot.img and recovery(2).img, since EMUI 8 they are splitted up into kernel, ramdisk (only 8, 10 and newer), (e)recovery_ramdisk and (e)recovery_vendor. Those images are basically regular bootimages with either kernel+cmdline, real offsets (which the bootloader cares about!!!!) and no ramdisk or a normal bootimage with ramdisk, the "default" offsets (they dont matter) and dummy kernel+cmdline. Those splitups are resolved on both [EMUI 8](https://github.com/hi6250-oss/android_device_huawei_hi6250-8-common/blob/lineage-18.1/mkbootimg.mk) and [EMUI 9](https://github.com/hi6250-oss/android_device_huawei_hi6250-9-common/blob/lineage-18.1/mkbootimg.mk) platform using a custom mkbootimg makefile. The "HW_MKBOOTIMG" is a edited mkbootimg by huawei which is in the kernel source to reproduce the 100% same offsets for the kernel.img.
Now I'm going to list some partitions on huawei devices:
* xloader: part of the bootloader, erase in fastboot to get into USB SER (IDT/Testpoint) mode.
* fastboot: the main part of the bootloader, DO NOT ERASE IT OR FLASH ONE WHICH DOESNT MATCH WITH THE XLOADER, ELSE YOUR DEVICE WILL BRICK AND ONLY TESTPOINTING WILL SAVE YOU!!!
* fw_lpm3, fw_hifi, sensorhub: firmware
* teeos, trustfirmware, sec_storage: TEE
* splash2: logs
* cust, version: EMUI parts (unused on AOSP)
* product: contains EMUI parts and on EMUI 5 also device specific configs etc., this will be fun when doing Pie and newer..., partition too small for AOSP product, can just be dropped on EMUI 8 and newer.
* odm (EMUI 8 and newer): contains device specific configs, instead in product like on EMUI 5, can be built from src.
* preas (EMUI 8 and newer): contains Google apps on EU firmware and some launcher stuff (gets mounted by dt fstab)
* preavs (EMUI 8 and newer): contains the widevine hal (move it to vendor, gets mounted by dt fstab)
* preload (EMUI 9 and newer): preinstalled apps I guess, mounted by dt fstab.
* nvme: contains device infos like SN, macs, unlock code, etc. DO NOT TOUCH!!
* oeminfo: contains device model and region, on newer phones (k970) also stuff from nvme and imeis, DON'T TOUCH!!!
* modem_fw, modemnvm_update: modem firmware
* modemnvm_*: contains your imei and other ril related stuff, DO NOT TOUCH!!!
  
## Basic bringup

