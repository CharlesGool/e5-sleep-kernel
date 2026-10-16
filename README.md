# e5-sleep 内核 · Deep Sleep Kernel for Rongyue E5

容悦 E5（展锐 UMS9621）OpenWrt 的深度休眠内核：`6.18.54-e5-sleep1`

*A kernel for the Rongyue E5 running OpenWrt (e5-linux) that can sleep: the PMIC watchdog stopped across system suspend, CPU idle states, and a display driver warning fixed*

在官方 E5 内核 `6.18.54-e5-mobile4`（e5-linux 2026-10-13 刷机包）的基础上：

| 改动 | 说明 |
|---|---|
| [0001](patches/0001-watchdog-ump9620-stop-across-system-suspend.patch) PMIC 看门狗挂起时停表 | `ump9620-pmic-wdt` 没有挂起处理，PMIC 休眠时照样计时，procd 被冻结无法喂狗，睡满 30 秒整机复位并回退进 Android |
| [0002](patches/0002-sprd-dpu-no-cancel-of-uninitialised-wb-work.patch) 显示驱动 | dpu_r6p1 未初始化 `wb_work` 却在每次挂起时 `cancel_work_sync()`，打印 WARNING |
| [0003](patches/0003-e5-mainline-config-cpuidle.patch) CPU 空闲状态 | 原内核 `CONFIG_CPU_IDLE` 未开，空闲核心只会 WFI；厂商设备树里的 PSCI 核心 / 簇断电状态（core-sleep、cluster-pd）现在能用了 |

配合[热点省电](https://github.com/CharlesGool/e5-hotspot-saver) v2.5 的深度休眠使用（关热点、熄屏后系统挂起到内存）。

## 实测

- 启动正常：92 个模块加载、0 失败，无 WARNING / Oops；调频 `sprd-cpufreq-v2` 正常（614 MHz–1.69 GHz）。
- cpuidle：`psci_idle` + `menu`，开机后约 200 秒内 CPU0 有约 47% 时间在核心断电或簇断电状态。
- 深度休眠：休眠 118 秒后电源键唤醒、屏幕点亮；挂起时不再有显示驱动 WARNING。
- 看门狗补丁未单独验证（没有 ftrace；直接让它睡过 30 秒而不停看门狗，失败会复位回 Android），
  热点省电的 sleep.sh 仍在挂起前后停 / 启看门狗，两者叠加无害。
- 休眠电流尚未长时间实测。

## 安装

**只适用于** 用 2026-10-13 刷机包（OpenWrt 25.12.5，内核 e5-mobile4）安装到手机存储（userdata）的 E5。
安装脚本会检查 boot_b 是否正是这个刷机包的镜像，不是就拒绝。

1. 下载 [`releases/`](releases) 里的 `e5-sleep1-boot-head.img.gz`、`e5-sleep1-modules.tar.gz`
   和 [`install/e5-sleep1-install.sh`](install/e5-sleep1-install.sh)，USB 连着电脑传到设备上同一个目录，例如：

   ```sh
   scp e5-sleep1-boot-head.img.gz e5-sleep1-modules.tar.gz e5-sleep1-install.sh root@192.168.9.1:/tmp/
   ```

2. SSH 登录设备，先检查（不写入任何东西），再安装：

   ```sh
   cd /tmp && sh e5-sleep1-install.sh --check && sh e5-sleep1-install.sh
   ```

   脚本会：校验文件；把模块装进 `/lib/modules/6.18.54-e5-sleep1-…`（原内核的模块不动）；
   把原 boot_b 备份到 `/mnt/e5-data/e5linux/boot_b-mobile4.img`，并放恢复脚本；写入新 boot_b 并读回校验。

3. `reboot`，约 2–3 分钟后 `uname -r` 应显示 `6.18.54-e5-sleep1-00072-g020b970e351e-dirty`。

新内核起不来时，bootloader 会自动回退进 Android（`e5-boot-ok` 只在系统完全起来后才重新标记 B 槽）。

## 从 Android 切回 OpenWrt

原版刷机包的 `flash.cmd --boot-openwrt` 会因 boot_b 哈希不同而拒绝（`boot_b holds another boot image`）。用：

- Magisk 的 E5 Linux 切回模块（只检查 boot_b 的 init，能通过）；或
- [`releases/Openwrt_E5_BootOpenwrt_sleep1.zip`](releases/Openwrt_E5_BootOpenwrt_sleep1.zip)：配新内核 boot.json 的精简刷机包，
  **只**支持 `flash.cmd --boot-openwrt`，其他命令一律拒绝（包里没有 rootfs 镜像）。

## 回到原内核

在 Android 里（adb + Magisk root）：

```sh
adb shell su -c sh /data/e5linux/restore-boot-b.sh
```

再用**原版**刷机包 `flash.cmd --boot-openwrt` 切回。原版包的 `--update` 也会把 boot_b 换回原内核。

## 自己编译

x86_64 Linux + Docker：

```sh
bash build/build-e5-sleep1.sh ./work          # 约 5 分钟（20 核）
REF=1 bash build/build-e5-sleep1.sh ./work    # 不加补丁的 e5-mobile4，用来和设备上的比较
python3 tools/repack-boot.py <刷机包>/files/boot.img work/dist-sleep1/Image.lk work/dist-sleep1/modules boot-e5-sleep1.img
```

构建用 e5-linux `569f13d` 的官方流程（`device/linux_device_e5/build-kernel.sh`：`prepare-kernel.py` 向干净的
linux-lts-e5 `020b970e351e` 注入 cpufreq v2 / SIP 服务、OTG、充电和 Wi-Fi 修复），在 e5-linux 的 `upstream/Dockerfile`
容器里（Ubuntu clang / lld 21.1.8，与设备内核相同）。`REF=1` 编出的 e5-mobile4 与设备上的一致：158 个模块大小全部相同，
Image.lk 同为 31262728 字节。

`tools/repack-boot.py` 以刷机包的 boot.img 为底，只换内核和 initramfs 里的 45 个 `.ko`，
init、busybox、f2fs 修复工具逐字节保留，vbmeta 和 AVB 尾部照搬（这台已解锁的设备不强制 AVB）。

## 诊断工具

- [`tools/e5-sleep-diag.sh`](tools/e5-sleep-diag.sh)：只读诊断（mem_sleep、唤醒源、中断、cpuidle…）
- [`tools/e5-suspend-test.sh`](tools/e5-suspend-test.sh)：一次 RTC 唤醒的挂起测试
- [`tools/e5-autosleep-trial.sh`](tools/e5-autosleep-trial.sh)：拔线后清醒 / 自动休眠各一段的对比

## 许可

内核补丁与内核、模块二进制：GPL-2.0（源码：[sprd-linux-devs/linux](https://github.com/sprd-linux-devs/linux) e5-6.18 分支
`020b970e351e`、[sprd-linux-devs/e5-linux](https://github.com/sprd-linux-devs/e5-linux) `569f13d` 及其子模块，加本仓库 `patches/`）。
脚本与工具：MIT。initramfs 内容来自 e5-linux 2026-10-13 刷机包，许可同其上游。

本内核为非官方修改，与荣悦及设备、芯片厂商无关。刷机有风险，请先备份，风险自负。
