#!/bin/sh
# AP deep-sleep A/B test, run detached on the E5 (OpenWrt).  Waits for the USB
# cable to be pulled, then suspends (RTC wake) in three configurations:
#   base     as booted
#   cam      + sprd_camsys_pd.ko (camera power domain forced off)
#   cam+gpu  + panfrost.ko with the system-suspend GPU power-off patch
# and logs the PMU sleep counters, the GPU/camera power state and TF-A's
# sprd_pdbg snapshot (e5_pdbg.ko) for each.  The hotspot saver's sleep.sh is
# paused (SIGSTOP) for the test and resumed afterwards; the PMIC watchdog is
# closed with the magic character around each suspend, as sleep.sh does.
# Usage: apdeep-test.sh [seconds per suspend]   log: /mnt/e5-data/e5-sleep/apdeep-*.log
D=/mnt/e5-data/e5-sleep
SECS=${1:-45}
LOG=$D/apdeep-$(date +%m%d-%H%M%S).log
PMU=/sys/kernel/debug/regmap/dummy-syscon@0x0000000064910000/registers
AON=/sys/kernel/debug/regmap/dummy-syscon@0x0000000064900000/registers
RTC=/sys/class/rtc/rtc0
UDC=$(ls -d /sys/class/udc/* | head -1)

reg() { grep "^$2:" "$1" | cut -d' ' -f2; }
st() { cat /sys/power/suspend_stats/$1; }
snap() {
	echo "   ap_deep=$(reg $PMU 0dfc) ap_light=$(reg $PMU 0e68) pub_deep=$(reg $PMU 0e60)" \
	     "chip=$(reg $PMU 0f3c) pscp_deep=$(reg $PMU 0e00)"
	echo "   pd_gpu_cfg=$(reg $PMU 02c4) pd_cam_cfg=$(reg $PMU 02e8) pwr_dbg4(gpu)=$(reg $PMU 0500)" \
	     "pwr_dbg6(cam)=$(reg $PMU 0508) aon_eb0=$(reg $AON 0000) audcp=$(reg $AON 014c)"
}
wdt_off() {
	ubus call system watchdog '{"magicclose": true}' >/dev/null 2>&1
	ubus call system watchdog '{"stop": true}' >/dev/null 2>&1
}
wdt_on() { ubus call system watchdog '{"stop": false}' >/dev/null 2>&1; }

cycle() {
	echo
	echo "-- $1: $(date +%T) success=$(st success) fail=$(st fail)"
	snap
	dmesg -c >/dev/null
	wdt_off
	echo 0 > $RTC/wakealarm; echo +$SECS > $RTC/wakealarm
	sync
	t0=$(cut -d' ' -f1 /proc/uptime)
	if echo mem > /sys/power/state; then rc=0; else rc=$?; fi
	wdt_on
	echo "   rc=$rc $(date +%T) success=$(st success) fail=$(st fail)" \
	     "last_failed=$(st last_failed_dev)/$(st last_failed_step) wakeup_irq=$(cat /sys/power/pm_wakeup_irq 2>/dev/null)"
	snap
	dmesg | grep -E 'e5_pdbg|PM: suspend|[Aa]bort|panfrost|camsys|PM: .*failed' | sed 's/^/   /'
	sleep 5
}

SLEEPPID=$(pgrep -f hotspotdata/sleep.sh)
{
	echo "== $(date) $(uname -r) secs=$SECS sleep.sh=$SLEEPPID"
	[ -n "$SLEEPPID" ] && kill -STOP $SLEEPPID
	lsmod | grep -q e5_pdbg || insmod $D/e5_pdbg.ko
	echo "waiting for USB unplug (udc=$(cat $UDC/state))"
	i=0
	while [ "$(cat $UDC/state)" = configured ] || [ "$(cat /sys/class/power_supply/usb/online)" = 1 ]; do
		sleep 1; i=$((i + 1)); [ $i -ge 1800 ] && { echo "timeout waiting for unplug"; break; }
	done
	echo "unplugged after ${i}s"
	sleep 5

	cycle base

	insmod $D/sprd_camsys_pd.ko && echo "camsys loaded: $(dmesg | grep -i camsys | tail -1)"
	cycle cam

	/etc/init.d/e5-infoscreen stop; sleep 3
	for p in /proc/[0-9]*; do ls -l $p/fd 2>/dev/null | grep -q renderD128 && { echo "killing $(cat $p/comm)"; kill $(basename $p); }; done
	sleep 2
	rmmod panfrost && insmod $D/panfrost.ko && echo "patched panfrost loaded"
	sleep 2
	echo "   after swap: pwr_dbg4(gpu)=$(reg $PMU 0500) pd_gpu_cfg=$(reg $PMU 02c4)"
	cycle cam+gpu
	cycle cam+gpu-2

	/etc/init.d/e5-infoscreen start
	[ -n "$SLEEPPID" ] && kill -CONT $SLEEPPID
	echo
	echo "== $(date) done"
} > $LOG 2>&1
