#!/bin/bash
# Build the e5-sleep1 kernel from scratch on an x86_64 Linux host with Docker.
#
#   build/build-e5-sleep1.sh [WORK]          (default WORK: ./work)
#   REF=1 build/build-e5-sleep1.sh           the e5-mobile4 kernel instead, unpatched (to compare)
#   SLEEP2=1 build/build-e5-sleep1.sh        e5-sleep2: + patches 0004/0005, the camera power domain built in
#
# It is the official E5 kernel build (e5-linux device/linux_device_e5/build-kernel.sh:
# prepare-kernel.py puts cpufreq v2 / the SIP service, OTG, charger and Wi-Fi fixes into
# a clean linux-lts-e5 020b970e351e), run in e5-linux's upstream/Dockerfile container
# (Ubuntu 26.04, clang/lld 21.1.8 as the device's kernel), plus patches/0001 and 0002,
# the cpuidle options of patches/0003 and LOCALVERSION -e5-sleep1.
#
# Out: WORK/dist-<name>/{Image.lk,modules/,config,kernel.release}. Then, for the boot image:
#   tools/repack-boot.py <package>/files/boot.img WORK/dist-sleep1/Image.lk WORK/dist-sleep1/modules boot.img
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
W=$(mkdir -p "${1:-$PWD/work}" && cd "${1:-$PWD/work}" && pwd)
E5_LINUX_COMMIT=569f13d4ce15585f70817c2a1e03bb574a84720b
KERNEL_COMMIT=020b970e351eee3887e6caaf2d653926e7086e44
if [ "${REF:-}" = 1 ]; then NAME=ref LV=-e5-mobile4 SLEEP=0
elif [ "${SLEEP2:-}" = 1 ]; then NAME=sleep2 LV=-e5-sleep2 SLEEP=2
else NAME=sleep1 LV=-e5-sleep1 SLEEP=1; fi

cd "$W"
if [ ! -d e5-linux ]; then
    git clone -q https://github.com/sprd-linux-devs/e5-linux e5-linux
fi
git -C e5-linux checkout -q $E5_LINUX_COMMIT
git -C e5-linux submodule update -q --init --depth 50 device/linux_device_common device/linux_device_e5
if [ ! -d linux ]; then
    # (the release string needs v6.18.54 in reach: -00072-g020b970e351e)
    git clone -q --depth 120 -b e5-6.18 https://github.com/sprd-linux-devs/linux.git linux
    git -C linux fetch -q --depth 120 origin tag v6.18.54
fi
rm -rf "k-$NAME"; git -C linux worktree prune
git -C linux worktree add -q --detach "$W/k-$NAME" $KERNEL_COMMIT
cp "$HERE"/patches/000[1245]-*.patch "$W/"
docker image inspect e5-mainline-build >/dev/null 2>&1 || docker build -q -t e5-mainline-build e5-linux/upstream/

# (mounted at its own path: the worktree's .git points there)
exec docker run --rm -v "$W":"$W" -e W="$W" -e NAME=$NAME -e LV=$LV -e SLEEP=$SLEEP -e JOBS="$(nproc)" e5-mainline-build bash -c '
set -euo pipefail
TOP=$W/e5-linux K=$W/k-$NAME O=$W/obj-$NAME DEST=$W/dist-$NAME
rm -rf $O $DEST; mkdir -p $O $DEST/modules
cd $K
python3 $TOP/device/linux_device_e5/prepare-kernel.py $K
if [ "$SLEEP" != 0 ]; then
    patch -p1 -N < $W/0001-watchdog-ump9620-stop-across-system-suspend.patch
    patch -p1 -N < $W/0002-sprd-dpu-no-cancel-of-uninitialised-wb-work.patch
fi
if [ "$SLEEP" = 2 ]; then
    patch -p1 -N < $W/0004-drm-panfrost-sprd-power-the-GPU-off-across-system-su.patch
    patch -p1 -N < $W/0005-soc-sprd-add-the-UMS9621-camera-subsystem-power-doma.patch
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
if sleep in ("1", "2"):
    text += "\nCONFIG_CPU_IDLE=y\nCONFIG_CPU_IDLE_GOV_MENU=y\nCONFIG_CPU_IDLE_GOV_TEO=y\nCONFIG_ARM_PSCI_CPUIDLE=y"
if sleep == "2":
    text += "\nCONFIG_SPRD_CAMSYS_PD=y"
output.write_text(text + "\n")
PY
args=(O=$O ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu-)
make "${args[@]}" allnoconfig >/dev/null
scripts/kconfig/merge_config.sh -m -O $O $O/.config $O/features.config >/dev/null
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
make "${args[@]}" -j$JOBS Image modules > $O/build.log 2>&1 || { tail -60 $O/build.log; exit 1; }
cp $O/arch/arm64/boot/Image $O/System.map $DEST/
cp $O/.config $DEST/config
cp $O/include/config/kernel.release $DEST/kernel.release
python3 $TOP/upstream/wrap-image.py $DEST/Image $DEST/Image.lk
make "${args[@]}" INSTALL_MOD_PATH=$O/staged INSTALL_MOD_STRIP=1 modules_install
find $O/staged/lib/modules/$(cat $DEST/kernel.release) -name "*.ko" -exec cp {} $DEST/modules/ \;
echo "== $(cat $DEST/kernel.release): $(ls $DEST/modules | wc -l) modules, Image.lk $(stat -c %s $DEST/Image.lk) bytes"
'
