#!/bin/sh
# Install the e5-sleep1 kernel on a Rongyue E5 running OpenWrt (e5-linux, kernel e5-mobile4).
# Run as root on the device, in the directory holding the release files:
#
#   sh e5-sleep1-install.sh --check     everything is checked, nothing is written
#   sh e5-sleep1-install.sh             modules, boot_b backup, boot_b; then reboot by hand
#
# Release files (releases/ of the repository):
#   e5-sleep1-boot-head.img.gz   the first 56 MiB of the new boot_b (kernel + initramfs)
#   e5-sleep1-modules.tar.gz     the kernel's 158 modules, flat
#
# What it does:
#   * refuses unless boot_b holds the boot image of the 2026-10-13 flash package
#     (e5-mobile4) or already this one, the device is an E5, and the files verify;
#   * puts the new modules into /lib/modules/<new release>, in the same layout as
#     the running kernel's directory (the old one is not touched);
#   * keeps the old boot_b in /mnt/e5-data/e5linux/boot_b-mobile4.img (Android:
#     /data/e5linux/) with restore-boot-b.sh next to it;
#   * writes the new image to boot_b and reads it back.
# A kernel that does not come up falls back to Android (e5-boot-ok re-arms slot b only
# once the system is up); restore there with: adb shell su -c sh /data/e5linux/restore-boot-b.sh
set -eu

NEW=6.18.54-e5-sleep1-00072-g020b970e351e-dirty
OLD_REL=6.18.54-e5-mobile4-00072-g020b970e351e-dirty
HEAD_OLD=32bd8f6ed1e2c983cfa55d902ba0e2ef0294a503d9aeb5e9798e54b782761f0a
HEAD_NEW=9f8bd89d321cdf5cc7a9fe0a0f7d247ae15061943ff81cda7b78a88470618abf
SHA_HEADGZ=116d30c77b4160f2ec14d13593b2ac2b89391c1cc6cc8bf79a4a7f04b2b2707a
SHA_MODS=f22f1a22ad76ea4010c7c5cc9d12ee2e857d6f13edc35758b245dfce3684e770
MB=56
D=/mnt/e5-data/e5linux
CHECK=
[ "${1:-}" = --check ] && CHECK=1

die() { echo "error: $*" >&2; exit 1; }
say() { echo "== $*"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || die "run as root"
[ "$(cat /etc/e5/device-profile 2>/dev/null || echo e5)" = e5 ] || die "not an E5 (/etc/e5/device-profile)"
for f in e5-sleep1-boot-head.img.gz e5-sleep1-modules.tar.gz; do [ -f "$f" ] || die "missing $f"; done
say "verifying the release files"
[ "$(sha e5-sleep1-boot-head.img.gz)" = "$SHA_HEADGZ" ] || die "e5-sleep1-boot-head.img.gz does not verify: download it again"
[ "$(sha e5-sleep1-modules.tar.gz)" = "$SHA_MODS" ] || die "e5-sleep1-modules.tar.gz does not verify: download it again"
[ "$(gunzip -c e5-sleep1-boot-head.img.gz | sha256sum | cut -d' ' -f1)" = "$HEAD_NEW" ] || die "the boot image does not unpack to what it should"

BOOTB=
for u in /sys/class/block/mmcblk*p*/uevent; do
	grep -qx PARTNAME=boot_b "$u" && BOOTB=/dev/$(basename "$(dirname "$u")")
done
[ -n "$BOOTB" ] || die "boot_b not found"
cur=$(dd if="$BOOTB" bs=1M count=$MB 2>/dev/null | sha256sum | cut -d' ' -f1)
case "$cur" in
	"$HEAD_OLD") state=old ;;
	"$HEAD_NEW") state=new ;;
	*) die "boot_b holds another boot image ($cur): this release is for the 2026-10-13 package (e5-mobile4) only" ;;
esac
say "boot_b ($BOOTB): $([ $state = old ] && echo 'the e5-mobile4 package image' || echo 'already e5-sleep1')"

# the layout of the modules: the e5-mobile4 directory's (flat, audio/, modem/)
REF=/lib/modules/$OLD_REL
[ -d "$REF" ] || REF=/lib/modules/$(uname -r)
[ -d "$REF" ] || die "no module directory to take the layout from"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
gunzip -c e5-sleep1-modules.tar.gz | tar -xf - -C "$T"
[ -d "$T/modules" ] || die "the module archive has no modules/"
miss=$(cd "$REF" && find . -name '*.ko' | while read -r p; do [ -f "$T/modules/$(basename "$p")" ] || echo "$p"; done)
[ -z "$miss" ] || die "modules missing in the release: $miss"
n=$(cd "$REF" && find . -name '*.ko' | wc -l)
need=$(du -sk "$T/modules" | cut -f1)
free=$(df -k / | awk 'NR == 2 { print $4 }')
[ "$free" -gt $((need + 8192)) ] || die "not enough space on / ($free KiB free, $need KiB needed)"
say "modules: $n in the layout of $REF"

if [ -d /mnt/e5-data ] && [ -w /mnt/e5-data ]; then
	BK=$D/boot_b-mobile4.img
else
	die "/mnt/e5-data is not writable (an SD install): back boot_b up by hand first"
fi

if [ -n "$CHECK" ]; then
	say "check passed; nothing written (run without --check to install)"
	exit 0
fi

say "installing the modules into /lib/modules/$NEW"
(cd "$REF" && find . -name '*.ko') | while read -r p; do
	mkdir -p "/lib/modules/$NEW/$(dirname "$p")"
	cp "$T/modules/$(basename "$p")" "/lib/modules/$NEW/$p"
done
sync

if [ $state = old ] && [ ! -f "$BK" ]; then
	say "backing boot_b up to $BK"
	mkdir -p "$D"
	dd if="$BOOTB" of="$BK" bs=1M 2>/dev/null
	sync
	[ "$(dd if="$BK" bs=1M count=$MB 2>/dev/null | sha256sum | cut -d' ' -f1)" = "$HEAD_OLD" ] || die "the backup does not verify"
	sha "$BK" > "$BK.sha256"
	cat > "$D/restore-boot-b.sh" <<-'EOF'
	#!/system/bin/sh
	# Put the original e5-mobile4 boot image back into boot_b (as root in Android:
	#   adb shell su -c sh /data/e5linux/restore-boot-b.sh
	# then the original package's flash.cmd --boot-openwrt, or the Magisk switch module).
	set -e
	D=/data/e5linux
	IMG=$D/boot_b-mobile4.img
	want=$(cat $IMG.sha256)
	[ "$(sha256sum $IMG | cut -d" " -f1)" = "$want" ] || { echo "backup does not verify"; exit 1; }
	dd if=$IMG of=/dev/block/by-name/boot_b bs=1048576 conv=fsync
	sync
	[ "$(sha256sum /dev/block/by-name/boot_b | cut -d" " -f1)" = "$want" ] && echo "boot_b restored (e5-mobile4)" || { echo "boot_b readback failed"; exit 1; }
	EOF
	chmod 755 "$D/restore-boot-b.sh"
	sync
fi

if [ $state = old ]; then
	say "writing the e5-sleep1 boot image to $BOOTB"
	gunzip -c e5-sleep1-boot-head.img.gz | dd of="$BOOTB" bs=1M conv=fsync 2>/dev/null
	sync
	echo 3 > /proc/sys/vm/drop_caches
	got=$(dd if="$BOOTB" bs=1M count=$MB 2>/dev/null | sha256sum | cut -d' ' -f1)
	[ "$got" = "$HEAD_NEW" ] || die "boot_b readback failed ($got): restore with dd if=$BK of=$BOOTB bs=1M before rebooting"
fi
say "done: reboot to start $NEW (uname -r shows it)"
