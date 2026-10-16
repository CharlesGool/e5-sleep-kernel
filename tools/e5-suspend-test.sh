#!/bin/sh
# One suspend-to-RAM attempt with an RTC alarm as the wake source.
# Usage: e5-suspend-test.sh [seconds]   (log: /tmp/e5-suspend-test.log)
SECS=${1:-30}
LOG=/tmp/e5-suspend-test.log
RTC=/sys/class/rtc/rtc0

up() { awk '{print $1}' /proc/uptime; }                       # boottime-ish (includes suspend)
mono() { awk '/^now at/{print $3/1e9; exit}' /proc/timer_list; } # CLOCK_MONOTONIC (stops in suspend)

{
	echo "== $(date) suspend test, wake in ${SECS}s"
	cat /sys/power/mem_sleep
	echo "before: uptime=$(up) mono=$(mono) success=$(cat /sys/power/suspend_stats/success) fail=$(cat /sys/power/suspend_stats/fail)"
	dmesg -c >/dev/null 2>&1 || true
	echo 0 > $RTC/wakealarm
	echo +$SECS > $RTC/wakealarm
	echo "alarm=$(cat $RTC/wakealarm) now=$(cat $RTC/since_epoch)"
	sync
	echo deep > /sys/power/mem_sleep
	if echo mem > /sys/power/state; then rc=0; else rc=$?; fi
	echo "state write rc=$rc"
	echo "after: uptime=$(up) mono=$(mono) success=$(cat /sys/power/suspend_stats/success) fail=$(cat /sys/power/suspend_stats/fail)"
	for f in last_failed_dev last_failed_errno last_failed_step failed_prepare failed_suspend failed_suspend_late failed_suspend_noirq; do
		echo "$f=$(cat /sys/power/suspend_stats/$f 2>/dev/null | tr '\n' ' ')"
	done
	cat /sys/power/pm_wakeup_irq 2>/dev/null && echo "(pm_wakeup_irq)"
	echo "== dmesg"
	dmesg
} > $LOG 2>&1
