#!/bin/sh
# Trial: after the USB cable is pulled, Wi-Fi down, then
#   A) PHASE seconds awake (baseline), B) PHASE seconds of opportunistic suspend
# (wakeup_count protocol, back to sleep GRACE s after every wake).  The battery's
# coulomb counter gives the average current of each phase.  Wi-Fi back up at the end.
# Usage: e5-autosleep-trial.sh [phase_s] [grace_s]   (log: /tmp/e5-autosleep-trial.log)
PHASE=${1:-150}
GRACE=${2:-2}
LOG=/tmp/e5-autosleep-trial.log
RTC=/sys/class/rtc/rtc0
BAT=/sys/class/power_supply/battery
UDC=$(ls -d /sys/class/udc/* | head -1)
WS=/sys/kernel/debug/wakeup_sources

boot() { awk '{print $1}' /proc/uptime; }
mono() { awk '/^now at/{printf "%.3f", $3/1e9; exit}' /proc/timer_list; }
cc() { cat $BAT/charge_counter; }
# name -> wakeup_count (column 4): the sources that ended a suspend
wsnap() { awk 'NR>1{print $1, $4}' $WS; }
calc() { awk "BEGIN{printf \"%.1f\", $1}"; }
wdt_off() { ubus call system watchdog '{"magicclose": true}' >/dev/null; ubus call system watchdog '{"stop": true}' >/dev/null; }
wdt_on() { ubus call system watchdog '{"stop": false}' >/dev/null; }
trap wdt_on EXIT

mount | grep -q debugfs || mount -t debugfs none /sys/kernel/debug
{
	echo "== $(date) trial: phase=${PHASE}s grace=${GRACE}s; waiting for USB unplug"
	i=0
	while [ "$(cat $UDC/state)" = configured ] || [ "$(cat /sys/class/power_supply/usb/online)" = 1 ]; do
		sleep 1; i=$((i + 1)); [ $i -ge 600 ] && { echo "timeout waiting for unplug"; exit 1; }
	done
	echo "unplugged after ${i}s"
	ap=0; iw dev 2>/dev/null | grep -q 'type AP' && ap=1
	[ $ap = 1 ] && { wifi down radio0; sleep 5; }
	echo "ap_was_up=$ap: $(iw dev 2>/dev/null | grep -c Interface) interfaces; backlight=$(cat /sys/class/backlight/*/brightness)"

	# --- A: awake baseline
	c0=$(cc); b0=$(boot)
	sleep $PHASE
	c1=$(cc); b1=$(boot)
	ma=$(calc "($c0 - $c1) / 1000 / (($b1 - $b0) / 3600)")
	echo "A awake: ${PHASE}s, charge ${c0} -> ${c1} uAh, avg ${ma} mA, now current_now=$(cat $BAT/current_now)"

	# --- B: opportunistic suspend
	dmesg -c >/dev/null
	end=$(( $(date +%s) + PHASE ))
	echo 0 > $RTC/wakealarm; echo $end > $RTC/wakealarm
	c0=$(cc); b0=$(boot); m0=$(mono); n=0; ok=0; slept=0
	wsnap > /tmp/ws.prev
	while [ "$(date +%s)" -lt "$end" ]; do
		cnt=$(cat /sys/power/wakeup_count)        # blocks while a wakeup source is active
		[ "$(date +%s)" -lt "$end" ] || break
		if ! echo "$cnt" > /sys/power/wakeup_count 2>/dev/null; then
			echo "  $(date +%T) wakeup event in progress, retry"; sleep 1; continue
		fi
		n=$((n + 1)); t0=$(boot); s0=$(mono)
		# the PMIC watchdog keeps counting in suspend (no PM ops in ump9620-pmic-wdt):
		# procd closes it with the magic character, which stops it, and re-arms it after
		wdt_off
		if echo mem > /sys/power/state 2>/dev/null; then rc=ok; ok=$((ok + 1)); else rc=fail; fi
		wdt_on
		t1=$(boot); s1=$(mono)
		d=$(calc "($t1 - $t0) - ($s1 - $s0)")
		slept=$(calc "$slept + $d")
		wsnap > /tmp/ws.now
		by=$(awk 'NR==FNR{p[$1]=$2; next} $2 > p[$1] {printf "%s+%d ", $1, $2 - p[$1]}' /tmp/ws.prev /tmp/ws.now)
		mv /tmp/ws.now /tmp/ws.prev
		echo "  $(date +%T) #$n $rc slept=${d}s woke_by: ${by:-?}$( [ $rc = fail ] && echo " failed_dev=$(cat /sys/power/suspend_stats/last_failed_dev)")"
		sleep $GRACE
	done
	c1=$(cc); b1=$(boot); m1=$(mono)
	mb=$(calc "($c0 - $c1) / 1000 / (($b1 - $b0) / 3600)")
	echo "B autosleep: $(calc "$b1 - $b0")s wall, slept ${slept}s ($(calc "100 * $slept / ($b1 - $b0)")%), attempts=$n ok=$ok"
	echo "B charge ${c0} -> ${c1} uAh, avg ${mb} mA (A was ${ma} mA)"
	echo 0 > $RTC/wakealarm
	[ $ap = 1 ] && wifi up radio0
	echo "== $(date) done (wifi restored: $ap)"
	echo "== dmesg (wake related)"
	dmesg | grep -iE 'PM: suspend|wakeup|wake up|Abort|failed|mailbox irq|smsg' | tail -80
} > $LOG 2>&1
