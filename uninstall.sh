#!/system/bin/sh
########################################
# Cepheus Tweaks (uninstall.sh) v1.0.0
#
# Kembalikan semua yang diubah modul ke nilai wajar/stok:
#   - CPU governor -> schedutil, batas frekuensi -> stok
#   - sched_boost=0, schedtune.boost=0
#   - GPU min_pwrlevel=6, governor msm-adreno-tz, force_* =0
#   - DDR/LLCC/gpubw -> nilai asli yang disimpan saat boot
#   - touch filter & network latency -> normal
#   - hidupkan mi_thermald & thermal-engine
########################################

MODDIR=$(dirname "$0")
[ -f "$MODDIR/service.sh" ] || MODDIR=/data/adb/modules/cepheus-tweaks

for p in policy0 policy4 policy7; do
	base=/sys/devices/system/cpu/cpufreq/$p
	echo schedutil > "$base/scaling_governor" 2>/dev/null
	[ -w "$base/scaling_max_freq" ] && cat "$base/cpuinfo_max_freq" > "$base/scaling_max_freq" 2>/dev/null
	[ -w "$base/scaling_min_freq" ] && cat "$base/cpuinfo_min_freq" > "$base/scaling_min_freq" 2>/dev/null
done

echo 0 > /proc/sys/kernel/sched_boost 2>/dev/null
echo 0 > /dev/stune/top-app/schedtune.boost 2>/dev/null

CB=/sys/module/cpu_boost/parameters
[ -w "$CB/input_boost_ms" ] && echo 120 > "$CB/input_boost_ms" 2>/dev/null
[ -w "$CB/sched_boost_on_input" ] && echo 0 > "$CB/sched_boost_on_input" 2>/dev/null

G=/sys/class/kgsl/kgsl-3d0
echo 6 > "$G/min_pwrlevel" 2>/dev/null
echo msm-adreno-tz > "$G/devfreq/governor" 2>/dev/null
echo 675000000 > "$G/devfreq/max_freq" 2>/dev/null
for f in force_clk_on force_bus_on force_rail_on; do echo 0 > "$G/$f" 2>/dev/null; done

# pastikan pengisian baterai kembali normal (matikan bypass charging)
echo 1 > /sys/class/power_supply/battery/charging_enabled 2>/dev/null
echo 0 > /sys/class/power_supply/battery/input_suspend 2>/dev/null

# pulihkan DDR/LLCC/gpubw ke nilai yang disimpan saat boot
if [ -r "$MODDIR/.ddr_orig" ]; then
	while IFS='|' read -r n omin omax ogov; do
		[ -n "$n" ] || continue
		p="/sys/class/devfreq/soc:qcom,$n"
		[ -d "$p" ] || continue
		[ -n "$omin" ] && [ -w "$p/min_freq" ] && echo "$omin" > "$p/min_freq" 2>/dev/null
		[ -n "$omax" ] && [ -w "$p/max_freq" ] && echo "$omax" > "$p/max_freq" 2>/dev/null
		[ -n "$ogov" ] && [ -w "$p/governor" ] && echo "$ogov" > "$p/governor" 2>/dev/null
	done < "$MODDIR/.ddr_orig"
fi

# touch filter normal
FTS=/sys/devices/platform/soc/c80000.i2c/i2c-2/2-0049
for f in glove_mode cover_mode charger_mode; do
	[ -w "$FTS/$f" ] && echo "{ 00000000 }" > "$FTS/$f" 2>/dev/null
done
[ -w "$FTS/grip_enable" ] && echo 0 > "$FTS/grip_enable" 2>/dev/null
[ -w "$FTS/grip_area" ] && echo 30 > "$FTS/grip_area" 2>/dev/null

# network latency normal
echo 4294967295 > /proc/sys/net/ipv4/tcp_notsent_lowat 2>/dev/null
echo 1 > /proc/sys/net/ipv4/tcp_autocorking 2>/dev/null
echo 1 > /proc/sys/net/ipv4/tcp_slow_start_after_idle 2>/dev/null
echo 0 > /proc/sys/net/ipv4/tcp_no_metrics_save 2>/dev/null
echo 0 > /proc/sys/net/core/busy_poll 2>/dev/null
echo 0 > /proc/sys/net/core/busy_read 2>/dev/null

start mi_thermald 2>/dev/null
start vendor.thermal-engine 2>/dev/null
