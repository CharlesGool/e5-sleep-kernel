#!/bin/bash
# Turn the 2026-10-13 package's openwrt.ext4 into the e5-sleep4 one:
#   + /lib/modules/<e5-sleep4> (stage-root-modules layout, from rm4/)
#   + the info-screen apps in /etc/e5-infoscreen/plugins (what `plugin install` does)
#   + t551m-sim-status timestamps on CLOCK_BOOTTIME (they survive a suspend)
set -euo pipefail
cd /root/e5/pkg
REL=6.18.54-e5-sleep4-00072-g020b970e351e-dirty
gzip -dc base/openwrt.ext4.gz > work.ext4
docker run --rm -v /root/e5/pkg:/p e5-mainline-build e2fsck -fn /p/work.ext4 >/dev/null
mkdir -p mnt
mount -o loop work.ext4 mnt
trap 'umount mnt 2>/dev/null || true' EXIT

# kernel modules
[ ! -e mnt/lib/modules/$REL ]
cp -a rm4/lib/modules/$REL mnt/lib/modules/
chown -R 0:0 mnt/lib/modules/$REL
echo "modules: $(find mnt/lib/modules/$REL -name '*.ko' | wc -l) in /lib/modules/$REL"

# info-screen apps, as /usr/libexec/e5-infoscreen/plugin install does
U=mnt/etc/e5-infoscreen/plugins
W=mnt/usr/share/e5-infoscreen/www/plugins
for f in plugins/*.tar.gz; do
	T=$(mktemp -d); tar -xzf "$f" -C "$T"
	[ -z "$(find "$T" -type l)" ] || { echo "$f has links"; exit 1; }
	src=$T; [ -f "$src/manifest.json" ] || src=$(dirname "$(ls "$T"/*/manifest.json)")
	id=$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert int(m["api_version"]) <= 2 and m["name"]; print(m["id"])' "$src/manifest.json")
	echo "$id" | grep -qE '^[a-z0-9][a-z0-9_-]{0,31}$'
	rm -rf "$U/$id"; cp -a "$src" "$U/$id"; chown -R 0:0 "$U/$id"; chmod -R u=rwX,go=rX "$U/$id"
	[ -d "$W/$id" ] && [ ! -L "$W/$id" ] && rm -rf "$W/$id"
	ln -sfn "/etc/e5-infoscreen/plugins/$id" "$W/$id"
	echo "app: $id $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$U/$id/manifest.json") ($(basename "$f"))"
	rm -rf "$T"
done

# SIM status timestamps: CLOCK_BOOTTIME (the readers use /proc/uptime)
S=mnt/usr/libexec/t551m-sim-status
n=$(grep -c "'updated': time.monotonic()" $S)
[ "$n" = 2 ]
sed -i "s/'updated': time.monotonic()/'updated': time.clock_gettime(time.CLOCK_BOOTTIME)/" $S
echo "sim-status: $n timestamps on CLOCK_BOOTTIME"

# what the package says it is
mkdir -p mnt/etc/e5
v=$(cat mnt/etc/e5/image-version); case "$v" in *+e5-sleep4) ;; *) echo "$v+e5-sleep4" > mnt/etc/e5/image-version ;; esac
date +%s > mnt/etc/e5/build-time
echo "image-version: $(cat mnt/etc/e5/image-version)"
printf '%s\n' "e5-sleep4 $(date -u +%FT%TZ): kernel $REL, apps $(ls $U | tr '\n' ' ')" > mnt/etc/e5/e5-sleep4.release
sync; umount mnt; trap - EXIT
docker run --rm -v /root/e5/pkg:/p e5-mainline-build e2fsck -fn /p/work.ext4 | tail -1
gzip -9 -n -c work.ext4 > openwrt-sleep4.ext4.gz
sha256sum openwrt-sleep4.ext4.gz; ls -la openwrt-sleep4.ext4.gz
