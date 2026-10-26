#!/bin/bash
# The official E5 kernel (device/linux_device_e5/build-kernel.sh) in the e5-mainline-build container.
#   build-e5.sh NAME LOCALVERSION SLEEP(0|1)
#   SLEEP=1: + the watchdog and DPU patches and cpuidle (/root/e5/in/kernel)
#   TOP=<e5-linux checkout> (default /root/e5/e5-linux)
#   SLEEP=3/4/5/6: + 0006 / + 0007 / + 0008 (fuel gauge relax_cnt_threshold) / + 0009 (suspend with VBUS, data off)
#   SLEEP=7: + 0010 (the Wi-Fi driver sends its firmware-reset uevent from the wiphy)
#   SLEEP=8: + 0011 (charger-manager sets the fuel gauge to full at the end of a charge)
#   SLEEP=9: the sprd-linux-devs/linux e5-6.18 base (b93bbc3a+, TOP at e5-linux 5ac9d504+): 0001-0005 and the
#            full-charge check (0011) are upstream there; + 0006-0010.  The release has no SCM suffix
#            (upstream: LOCALVERSION_AUTO=n): 6.18.54<LOCALVERSION>
#   SLEEP=2: SLEEP=1 + the GPU (0004) and camera power domain (0005) patches, camsys built in
set -euo pipefail
NAME=$1 LV=$2 SLEEP=$3
exec docker run --rm -v /root/e5:/root/e5 -e NAME="$NAME" -e LV="$LV" -e SLEEP="$SLEEP" -e TOP="${TOP:-/root/e5/e5-linux}" -e KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-root}" -e KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-e5-build}" -e JOBS=20 e5-mainline-build bash -c '
set -euo pipefail
TOP=${TOP:-/root/e5/e5-linux} K=/root/e5/k-$NAME O=/root/e5/obj-$NAME DEST=/root/e5/dist-$NAME
mkdir -p $O $DEST/modules
cd $K
# (SLEEP=9: the committed kernel baseline, as upstream checks it -- on the clean checkout, before the model adapter)
[ "$SLEEP" -lt 9 ] || python3 $TOP/upstream/check-kernel-source.py .
python3 $TOP/device/linux_device_e5/prepare-kernel.py $K
if [ "$SLEEP" -ge 9 ]; then
    export LOCALVERSION=
    for p in 0006 0007 0008 0009 0010; do patch -p1 -N < /root/e5/in/kernel/$p-*.patch; done
else
if [ "$SLEEP" != 0 ]; then
    patch -p1 -N < /root/e5/in/kernel/0001-watchdog-ump9620-stop-across-system-suspend.patch
    patch -p1 -N < /root/e5/in/kernel/0002-sprd-dpu-no-cancel-of-uninitialised-wb-work.patch
fi
if [ "$SLEEP" -ge 2 ]; then
    patch -p1 -N < /root/e5/in/kernel/0004-drm-panfrost-sprd-power-the-GPU-off-across-system-su.patch
    patch -p1 -N < /root/e5/in/kernel/0005-soc-sprd-add-the-UMS9621-camera-subsystem-power-doma.patch
fi
if [ "$SLEEP" -ge 3 ]; then
    patch -p1 -N < /root/e5/in/kernel/0006-usb-musb-sprd-release-the-USB3.1-PLL-across-system-suspend.patch
fi
if [ "$SLEEP" -ge 4 ]; then
    patch -p1 -N < /root/e5/in/kernel/0007-usb-musb-sprd-do-not-poll-while-USB-data-is-disabled.patch
fi
if [ "$SLEEP" -ge 5 ]; then
    patch -p1 -N < /root/e5/in/kernel/0008-power-supply-ump96xx-fgu-relax_cnt_threshold-module-parameter.patch
fi
if [ "$SLEEP" -ge 6 ]; then
    patch -p1 -N < /root/e5/in/kernel/0009-usb-musb-sprd-suspend-with-VBUS-while-USB-data-is-off.patch
fi
if [ "$SLEEP" -ge 7 ]; then
    patch -p1 -N < /root/e5/in/kernel/0010-sprd_wlan_combo-recovery-uevent-from-the-wiphy-device.patch
fi
if [ "$SLEEP" -ge 8 ]; then
    patch -p1 -N < /root/e5/in/kernel/0011-charger-manager-set-the-fuel-gauge-to-full-at-the-end-of-a-charge.patch
fi
fi
python3 - $TOP $O/features.config "$LV" "$SLEEP" <<PY
from pathlib import Path
import sys
top, output, lv, sleep = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4]
text = (top / "upstream/e5-mainline.config").read_text()
text = text.replace("CONFIG_LOCALVERSION=\"-e5\"", "CONFIG_LOCALVERSION=\"" + lv + "\"")
text = text.replace(" e5.openwrt=openwrt-mainline.ext4", "")
text += "\n" + (top / "device/linux_device_common/kernel/cpufreq/config").read_text()
for key in ("SCSI", "BLK_DEV_SD", "USB_STORAGE", "USB_UAS", "EXFAT_FS", "NTFS3_FS",
            "NLS_UTF8", "USB_USBNET", "USB_RTL8152", "USB_NET_AX8817X",
            "USB_NET_AX88179_178A", "USB_NET_CDCETHER", "USB_NET_CDC_NCM",
            "USB_NET_RNDIS_HOST", "USB_NET_SMSC75XX", "USB_NET_SMSC95XX"):
    text += "\nCONFIG_" + key + "=m"
if int(sleep) >= 1:
    text += "\nCONFIG_CPU_IDLE=y\nCONFIG_CPU_IDLE_GOV_MENU=y\nCONFIG_CPU_IDLE_GOV_TEO=y\nCONFIG_ARM_PSCI_CPUIDLE=y"
if int(sleep) >= 2:
    text += "\nCONFIG_SPRD_CAMSYS_PD=y"
output.write_text(text + "\n")
PY
args=(O=$O ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu-)
make "${args[@]}" allnoconfig >/dev/null
scripts/kconfig/merge_config.sh -m -O $O $O/.config $O/features.config >/dev/null
grep -q "^config NFS_V4_1$" fs/nfs/Kconfig && scripts/config --file $O/.config --enable NFS_V4_1
make "${args[@]}" olddefconfig >/dev/null
python3 - $O/features.config $O/.config $TOP/upstream/config-ignored.txt <<PY
from pathlib import Path
import sys
def config(path):
    return dict(l.split("=", 1) for l in Path(path).read_text().splitlines() if l.startswith("CONFIG_") and "=" in l)
wanted, actual = map(config, sys.argv[1:3])
ign = Path(sys.argv[3]).read_text().splitlines() if Path(sys.argv[3]).exists() else []
bad = [k for k, v in wanted.items() if actual.get(k, "n") != v and k not in ign]
if bad: raise SystemExit("Kernel options not accepted: " + ", ".join(bad))
PY
echo "== release $(make -s "${args[@]}" kernelrelease)"
make "${args[@]}" -j$JOBS Image modules > $O/build.log 2>&1 || { tail -60 $O/build.log; exit 1; }
cp $O/arch/arm64/boot/Image $O/System.map $DEST/
cp $O/.config $DEST/config
cp $O/include/config/kernel.release $DEST/kernel.release
python3 $TOP/upstream/wrap-image.py $DEST/Image $DEST/Image.lk
rm -rf $O/staged; make "${args[@]}" INSTALL_MOD_PATH=$O/staged INSTALL_MOD_STRIP=1 modules_install
release=$(cat $DEST/kernel.release)
find $DEST/modules -maxdepth 1 -type f -name "*.ko" -delete
find $O/staged/lib/modules/$release -name "*.ko" -exec cp {} $DEST/modules/ \;
tar -C $O/staged -cf $DEST/modules.tar lib/modules/$release
python3 $TOP/upstream/stage-root-modules.py $DEST || echo "stage-root-modules failed"
echo "== $release: $(ls $DEST/modules | wc -l) modules, Image.lk $(stat -c %s $DEST/Image.lk)"
'
