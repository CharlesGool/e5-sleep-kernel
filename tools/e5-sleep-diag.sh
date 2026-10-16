#!/bin/sh
# E5 OpenWrt: read-only sleep/power diagnostics. Changes nothing on the device.
# Usage: sh e5-sleep-diag.sh > diag.txt 2>&1

sec() { echo; echo "===== $* ====="; }
show() { for f in "$@"; do [ -e "$f" ] && printf '%s: %s\n' "$f" "$(cat "$f" 2>/dev/null | tr '\n' ' ')"; done; }

sec system
uname -a; cat /etc/openwrt_release 2>/dev/null | grep -E 'DISTRIB_(RELEASE|REVISION)'; uptime

sec "power state interface"
show /sys/power/state /sys/power/mem_sleep /sys/power/wake_lock \
     /sys/power/autosleep /sys/power/pm_async /sys/power/pm_test /sys/power/pm_debug_messages
sec suspend_stats
for f in /sys/power/suspend_stats/*; do show "$f"; done

sec "psci / cpuidle"
dmesg | grep -iE 'psci|cpuidle|idle state' | head -20
ls /sys/devices/system/cpu/cpuidle 2>/dev/null && show /sys/devices/system/cpu/cpuidle/*
ls /sys/devices/system/cpu/cpu0/cpuidle 2>/dev/null
show /sys/devices/system/cpu/online /sys/devices/system/cpu/offline
for c in /sys/devices/system/cpu/cpufreq/policy*; do
	show "$c/scaling_governor" "$c/scaling_cur_freq" "$c/scaling_min_freq" "$c/related_cpus"
done

sec "clock events / timers"
grep -E 'Clock Event Device|Broadcast|mode:' /proc/timer_list 2>/dev/null | sort | uniq -c | head -30
show /sys/devices/system/clockevents/broadcast/current_device /sys/devices/system/clocksource/clocksource0/current_clocksource

sec "wakeup-capable devices (enabled)"
find /sys/devices -path '*/power/wakeup' 2>/dev/null | while read -r w; do
	[ "$(cat "$w" 2>/dev/null)" = enabled ] && echo "${w%/power/wakeup}"
done

sec "active wakeup sources (debugfs)"
mount | grep -q debugfs || mount -t debugfs none /sys/kernel/debug 2>/dev/null
if [ -r /sys/kernel/debug/wakeup_sources ]; then
	head -1 /sys/kernel/debug/wakeup_sources
	awk 'NR>1 && ($2>0 || $6>0)' /sys/kernel/debug/wakeup_sources | sort -k6 -n -r | head -40
fi
sec "wakeup sources class"
for w in /sys/class/wakeup/wakeup*; do
	n=$(cat "$w/name" 2>/dev/null); a=$(cat "$w/active_count" 2>/dev/null)
	t=$(cat "$w/total_time_ms" 2>/dev/null); e=$(cat "$w/event_count" 2>/dev/null)
	[ "${e:-0}" -gt 0 ] && echo "$n events=$e active=$a total_ms=$t"
done | sort -t= -k2 -n -r | head -40

sec "kernel log: sipa / suspend / pm"
dmesg | grep -iE 'suspend|resum|PM:|sipa.*(sleep|suspend)|wakeup|freez' | tail -60

sec "interrupts (top)"
awk 'NR==1{next}{s=0; for(i=2;i<=9;i++) s+=$i; print s, $0}' /proc/interrupts | sort -n -r | head -30 | cut -c1-200

sec "rtc"
ls /sys/class/rtc; show /sys/class/rtc/rtc0/name /sys/class/rtc/rtc0/wakealarm /sys/class/rtc/rtc0/device/power/wakeup

sec "input devices"
for i in /sys/class/input/input*; do echo "$(basename $i): $(cat $i/name) wakeup=$(cat $i/device/power/wakeup 2>/dev/null)"; done
cat /sys/kernel/debug/gpio 2>/dev/null | grep -iE 'key|irq' | head

sec "screen / backlight / display"
for b in /sys/class/backlight/*; do show "$b/brightness" "$b/bl_power" "$b/actual_brightness"; done
for c in /sys/class/drm/card*-*; do show "$c/status" "$c/dpms" "$c/enabled"; done
uci -q get e5-infoscreen.main.idle

sec "network / hotspot"
iw dev 2>/dev/null | grep -E 'Interface|type|ssid'
for i in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do echo "$i stations: $(iw dev $i station dump 2>/dev/null | grep -c Station)"; done
ip -br link

sec "usb gadget"
show /sys/class/udc/*/state

sec "battery / charger"
for p in /sys/class/power_supply/*; do echo "$(basename $p):"; show "$p/status" "$p/online" "$p/capacity" "$p/current_now" "$p/voltage_now" "$p/power_now"; done

sec "busy processes (5s sample)"
top -b -n 2 -d 5 2>/dev/null | awk '/^Mem:/{n++} n==2' | head -25

sec "loaded modules"
lsmod 2>/dev/null | awk '{print $1}' | tr '\n' ' '; echo

sec "hotspot-saver / powermon state"
ls /etc/init.d | grep -iE 'hotspot|power|saver|sleep'
