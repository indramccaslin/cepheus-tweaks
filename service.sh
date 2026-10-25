#!/system/bin/sh
########################################
# Cepheus Tweaks (service.sh) v1.0.1
# Berdiri sendiri untuk KernelSU-Next (tanpa daemon tambahan).
#
# Saat game terdeteksi (app foreground ada di gamelist.txt):
#   CPU   : governor -> performance (pin ke freq max)
#   SCHED : sched_boost=1 + schedtune.boost top-app
#   GPU   : floor -> max (min_pwrlevel), governor game, opsional force clk
#   THERM : ambang zona step dinaikkan
#   UNLOCK: hentikan mi_thermald & thermal-engine + paksa cpu_limits ke max
#           (menembus throttle Xiaomi yang mengunci big-core di suhu rendah)
# Saat keluar game: semua dipulihkan ke nilai idle.
#
# MODE (tweak.conf):
#   global (default) = stok ROM: tidak ada tuning yang diterapkan. Modul hanya
#                      memulihkan nilai asli dan tidak menyentuh apa pun.
#   gaming           = perilaku di atas (profil lengkap saat game terdeteksi).
#
# Statis (hanya Mode Gaming): I/O scheduler/readahead, VM, NET, kernel.
# WebUI (webroot/) bisa mengubah gamelist.txt & tweak.conf lalu men-*touch*
# $MODDIR/.reload -> worker membaca ulang tanpa reboot.
#
# Catatan: pada kernel ini sconfig/temp_state milik Xiaomi vestigial
# (tak dibaca), jadi tuas CPU nyata = governor + stop mi_thermald + cpu_limits.
########################################

MODDIR=${MODDIR:-$(dirname "$0")}
CONF="$MODDIR/tweak.conf"
LOG="$MODDIR/tweak.log"
RELOAD="$MODDIR/.reload"

log() { echo "[cepheus-tweaks] $*" >> "$LOG"; }

# read_opt <key> <default>
read_opt() {
	local v
	v=$(sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -n1 | tr -d ' \r')
	[ -n "$v" ] && echo "$v" || echo "$2"
}

# read_raw <key> <default>  (tanpa membuang spasi di tengah, untuk nilai multi-bagian)
read_raw() {
	local v
	v=$(sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -n1 | tr -d '\r')
	[ -n "$v" ] && echo "$v" || echo "$2"
}

# Skrip ini dipanggil KernelSU-Next sebagai module service.sh (stage
# "late_start service", SETELAH boot) -> tidak memblok boot.
# Tetap di-detach (setsid) + PIDFILE supaya idempoten & lepas dari induk.
PIDFILE="$MODDIR/.worker.pid"
BOOTCOUNT="$MODDIR/.bootcount"
if [ "$1" != "--worker" ]; then
	# --- FAILSAFE anti-bootloop ---
	# Tiap kali dipanggil saat boot, naikkan counter. Worker menulis 0 hanya
	# setelah sistem terbukti stabil (lihat bawah). Bila 3x boot tanpa pernah
	# sukses, modul menonaktifkan dirinya sendiri (tak mungkin loop selamanya).
	c=$(cat "$BOOTCOUNT" 2>/dev/null)
	case "$c" in ''|*[!0-9]*) c=0 ;; esac
	c=$((c + 1))
	echo "$c" > "$BOOTCOUNT" 2>/dev/null
	if [ "$c" -gt 3 ]; then
		log "FAILSAFE: boot#$c tanpa sukses -> disable module"
		touch "$MODDIR/disable" 2>/dev/null
		rm -f "$BOOTCOUNT"
		exit 0
	fi
	# idempoten: cegah worker ganda
	if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
		exit 0
	fi
	: > "$LOG"
	log "invoked (v1.0.1) boot#$c"
	setsid "$0" --worker </dev/null >>"$LOG" 2>&1 &
	echo $! > "$PIDFILE"
	log "worker detached (pid $!)"
	exit 0
fi

# tunggu sampai boot benar-benar selesai
while [ -z "$(getprop sys.boot_completed)" ]; do sleep 10; done
sleep 15

	log "started (v1.0.1)"

# ---------------- paths ----------------
G=/sys/class/kgsl/kgsl-3d0
CPUFREQ=/sys/devices/system/cpu/cpufreq
STUNE=/dev/stune/top-app
THERMAL_MSG=/sys/class/thermal/thermal_message
GAMELIST="$MODDIR/gamelist.txt"
TZ_LIST="$MODDIR/.thermal_list"
DDR_LIST="$MODDIR/.ddr_orig"
STATIC_LIST="$MODDIR/.static_orig"
FTS=/sys/devices/platform/soc/c80000.i2c/i2c-2/2-0049
MSMPERF=/sys/module/msm_performance/parameters

# ---------------- helpers ----------------
# tulis hanya jika node writable
wr() { [ -w "$1" ] && { echo "$2" > "$1" 2>/dev/null; return 0; }; return 1; }

# valid_gov <nama> <daftar governor dipisah spasi>
valid_gov() {
	[ -n "$1" ] || return 1
	case " $2 " in *" $1 "*) return 0 ;; esac
	return 1
}

# buang nilai governor yang tidak didukung kernel (mis. conf diedit manual)
sanitize_governors() {
	local avail
	avail=$(cat "$CPUFREQ/policy0/scaling_available_governors" 2>/dev/null)
	if [ -n "$avail" ]; then
		valid_gov "$CPU_GAME_GOV" "$avail" || CPU_GAME_GOV=performance
		valid_gov "$CPU_IDLE_GOV" "$avail" || CPU_IDLE_GOV=schedutil
	fi
	avail=$(cat "$G/devfreq/available_governors" 2>/dev/null)
	if [ -n "$avail" ]; then
		valid_gov "$GPU_GAME_GOV" "$avail" || GPU_GAME_GOV=performance
		valid_gov "$GPU_IDLE_GOV" "$avail" || GPU_IDLE_GOV=msm-adreno-tz
	fi
}

fg_pkg() {
	dumpsys window 2>/dev/null \
		| sed -n 's/.*mCurrentFocus=[^ ]* u[0-9]* \([a-zA-Z0-9_.]*\)\/.*/\1/p' \
		| head -n1
}

# app foreground termasuk daftar game?
in_gamelist() {
	local pkg=$1
	[ -n "$pkg" ] || return 1
	grep -qxF "$pkg" "$GAMELIST" 2>/dev/null && return 0
	return 1
}

STATIC_GAME=0
game_active() {
	# mode statis: profil game dipakai terus
	[ "$STATIC_GAME" = "1" ] && return 0
	local fg
	# app di foreground termasuk daftar game?
	fg=$(fg_pkg)
	in_gamelist "$fg" && return 0
	return 1
}

# ---------------- config ----------------
load_config() {
	# MODE: global (default) = stok ROM, tanpa tuning apa pun. gaming = profil
	#       lengkap saat game terdeteksi.
	MODE=$(read_opt MODE global)
	case "$MODE" in global|gaming) ;; *) MODE=global ;; esac
	EN_CPU=$(read_opt GP_CPU true)
	EN_GPU=$(read_opt GP_GPU true)
	EN_IO=$(read_opt GP_IO true)
	EN_VM=$(read_opt GP_VM true)
	EN_NET=$(read_opt GP_NET true)
	EN_KERNEL=$(read_opt GP_KERNEL true)
	GP_DYN=$(read_opt GP_DYNAMIC true)
	# interval poll deteksi game (detik); kecil = responsif, besar = hemat daya
	GP_POLL=$(read_opt GP_POLL 2)
	case "$GP_POLL" in ''|*[!0-9]*) GP_POLL=2 ;; esac
	[ "$GP_POLL" -lt 1 ] && GP_POLL=1

	CPU_GAME_GOV=$(read_opt CPU_GAME_GOV performance)
	CPU_IDLE_GOV=$(read_opt CPU_IDLE_GOV schedutil)
	SCHED_BOOST=$(read_opt SCHED_BOOST true)
	STUNE_BOOST=$(read_opt STUNE_BOOST 20)
	SCHED_TUNE=$(read_opt SCHED_TUNE true)
	SCHED_LATENCY_NS=$(read_opt SCHED_LATENCY_NS 6000000)
	SCHED_MIN_GRA=$(read_opt SCHED_MIN_GRANULARITY_NS 1000000)
	SCHED_WAKEUP_GRA=$(read_opt SCHED_WAKEUP_GRANULARITY_NS 1000000)
	MSMPERF_MIN=$(read_opt MSMPERF_MIN 0)
	CPU_LOCK_MAX=$(read_opt CPU_LOCK_MAX true)
	# batas frekuensi tiap cluster saat game; 0/kosong/>hw max = tanpa batas
	LITTLE_MAX=$(read_opt LITTLE_MAX 1785600)
	MID_MAX=$(read_opt MID_MAX 2419200)
	PRIME_MAX=$(read_opt PRIME_MAX 2841600)
	case "$LITTLE_MAX" in ''|*[!0-9]*) LITTLE_MAX=1785600 ;; esac
	case "$MID_MAX" in ''|*[!0-9]*) MID_MAX=2419200 ;; esac
	case "$PRIME_MAX" in ''|*[!0-9]*) PRIME_MAX=2841600 ;; esac
	ALL_CORES_ONLINE=$(read_opt ALL_CORES_ONLINE true)
	CPU_BOOST_INPUT=$(read_opt CPU_BOOST_INPUT true)
	CPU_BOOST_MS=$(read_opt CPU_BOOST_MS 2000)
	SCHED_BOOST_ON_INPUT=$(read_opt SCHED_BOOST_ON_INPUT true)

	GPU_GAME_FLOOR=$(read_opt GPU_GAME_PWRLEVEL 0)
	GPU_IDLE_FLOOR=$(read_opt GPU_IDLE_PWRLEVEL 6)
	GPU_GAME_GOV=$(read_opt GPU_GAME_GOV performance)
	GPU_IDLE_GOV=$(read_opt GPU_IDLE_GOV msm-adreno-tz)
	GPU_FORCE_CLK=$(read_opt GPU_FORCE_CLK 0)
	GPU_IDLE_TIMER=$(read_opt GPU_IDLE_TIMER 80)
	# kunci GPU ke frekuensi tertinggi (max_gpuclk) selama game (pin min=max)
	GPU_GAME_LOCK=$(read_opt GPU_GAME_LOCK true)

	# bypass charging saat game: HP ditenagai adaptor, baterai tidak diisi
	# (mengurangi panas & throttling; hanya bila adaptor terpasang)
	EN_BYPASS=$(read_opt GP_BYPASS_CHARGE true)

	THERMAL_GAME=$(read_opt THERMAL_GAME true)
	GPU_TRIP_GAME=$(read_opt GPU_TRIP_GAME 92000)
	CPU_TRIP_GAME=$(read_opt CPU_TRIP_GAME 115000)
	# zona lmh-dcvs (hardware throttle 85C). Dinaikkan saat game agar LMH
	# mulai lebih lambat; dipulihkan saat idle. 0 = jangan diubah.
	LMH_TRIP_GAME=$(read_opt LMH_TRIP_GAME 95000)
	THERMAL_UNLOCK=$(read_opt THERMAL_UNLOCK true)
	TOUCH_GAME=$(read_opt TOUCH_GAME true)
	TOUCH_BOOST=$(read_opt TOUCH_BOOST true)
	TOUCH_GRIP_ENABLE=$(read_opt TOUCH_GRIP_ENABLE 0)
	TOUCH_GRIP_AREA=$(read_opt TOUCH_GRIP_AREA 0)

	# optimasi DDR/memory bandwidth saat game
	DDR_BOOST=$(read_opt DDR_BOOST true)

	IO_SCHED=$(read_opt IO_SCHED deadline)
	IO_READAHEAD_KB=$(read_opt IO_READAHEAD_KB 2048)
	IO_NR_REQUESTS=$(read_opt IO_NR_REQUESTS 256)

	VM_VFS=$(read_opt VM_VFS_CACHE_PRESSURE 60)
	VM_DWC=$(read_opt VM_DIRTY_WRITEBACK_CS 1000)
	VM_SWAPPINESS=$(read_opt VM_SWAPPINESS 10)
	VM_MIN_FREE_EXTRA=$(read_opt VM_MIN_FREE_EXTRA_KB 32768)
	VM_STAT_INTERVAL=$(read_opt VM_STAT_INTERVAL 1)

	NET_LL=$(read_opt NET_TCP_LOW_LATENCY 1)
	NET_FASTOPEN=$(read_opt NET_TCP_FASTOPEN 3)
	NET_RMEM=$(read_opt NET_RMEM_MAX 6291456)
	NET_WMEM=$(read_opt NET_WMEM_MAX 6291456)
	NET_SOMAXCONN=$(read_opt NET_SOMAXCONN 1024)
	NET_BACKLOG=$(read_opt NET_TCP_SYN_BACKLOG 1024)
	NET_TCP_RMEM=$(read_raw NET_TCP_RMEM "4096 87380 6291456")
	NET_TCP_WMEM=$(read_raw NET_TCP_WMEM "4096 16384 6291456")
	# tuning latensi tambahan saat game (dipulihkan saat idle)
	NET_GAME_BOOST=$(read_opt NET_GAME_BOOST true)
	NET_NOTSOL_LOWAT=$(read_opt NET_NOTSOL_LOWAT 16384)
	NET_BUSY_POLL=$(read_opt NET_BUSY_POLL 50)
	NET_BUSY_READ=$(read_opt NET_BUSY_READ 50)
	NET_AUTOCORKING=$(read_opt NET_AUTOCORKING 0)
	NET_SLOW_START=$(read_opt NET_SLOW_START_AFTER_IDLE 0)
	NET_NO_METRICS=$(read_opt NET_NO_METRICS_SAVE 1)

	KERNEL_PERF=$(read_opt KERNEL_PERF_CPU_TIME 25)
	INOT_INST=$(read_opt INOTIFY_MAX_USER_INSTANCES 512)
	INOT_WATCH=$(read_opt INOTIFY_MAX_USER_WATCHES 524288)
	INOT_QUEUE=$(read_opt INOTIFY_MAX_QUEUED_EVENTS 32768)

	# mode statis (tanpa deteksi game) -> selalu profil game
	STATIC_GAME=0
	[ "$GP_DYN" != "true" ] && STATIC_GAME=1
}
load_config
sanitize_governors

# ---------------- simpan nilai asli (saat boot = stok) ----------------
ORIG_GOV0=$(cat "$CPUFREQ/policy0/scaling_governor" 2>/dev/null)
ORIG_GOV4=$(cat "$CPUFREQ/policy4/scaling_governor" 2>/dev/null)
ORIG_GOV7=$(cat "$CPUFREQ/policy7/scaling_governor" 2>/dev/null)
ORIG_GPU_PWRLEVEL=$(cat "$G/min_pwrlevel" 2>/dev/null)
ORIG_GPU_GOV=$(cat "$G/devfreq/governor" 2>/dev/null)
ORIG_GPU_IDLE_TIMER=$(cat "$G/idle_timer" 2>/dev/null)
ORIG_GPU_MIN_FREQ=$(cat "$G/devfreq/min_freq" 2>/dev/null)
ORIG_GPU_MAX_FREQ=$(cat "$G/devfreq/max_freq" 2>/dev/null)
ORIG_THERMAL_PWRLEVEL=$(cat "$G/thermal_pwrlevel" 2>/dev/null)
CHG_EN=/sys/class/power_supply/battery/charging_enabled
ORIG_CHG_EN=$(cat "$CHG_EN" 2>/dev/null)
USB_ON=/sys/class/power_supply/usb/present
[ -r "$FTS/glove_mode" ] && ORIG_GLOVE=$(cat "$FTS/glove_mode" 2>/dev/null)
[ -r "$FTS/cover_mode" ] && ORIG_COVER=$(cat "$FTS/cover_mode" 2>/dev/null)
[ -r "$FTS/charger_mode" ] && ORIG_CHARGER=$(cat "$FTS/charger_mode" 2>/dev/null)
[ -r "$FTS/grip_enable" ] && ORIG_GRIP_ENABLE=$(cat "$FTS/grip_enable" 2>/dev/null)
[ -r "$FTS/grip_area" ] && ORIG_GRIP_AREA=$(cat "$FTS/grip_area" 2>/dev/null)
ORIG_SCHED_LAT=$(cat /proc/sys/kernel/sched_latency_ns 2>/dev/null)
ORIG_SCHED_MIN=$(cat /proc/sys/kernel/sched_min_granularity_ns 2>/dev/null)
ORIG_SCHED_WAKE=$(cat /proc/sys/kernel/sched_wakeup_granularity_ns 2>/dev/null)
ORIG_MSMPERF=$(cat "$MSMPERF/cpu_min_freq" 2>/dev/null | tr -s ' ')
# scaling min/max per cluster (untuk kunci maksimum saat game)
ORIG_SMAX_0=$(cat "$CPUFREQ/policy0/scaling_max_freq" 2>/dev/null)
ORIG_SMAX_4=$(cat "$CPUFREQ/policy4/scaling_max_freq" 2>/dev/null)
ORIG_SMAX_7=$(cat "$CPUFREQ/policy7/scaling_max_freq" 2>/dev/null)
ORIG_SMIN_0=$(cat "$CPUFREQ/policy0/scaling_min_freq" 2>/dev/null)
ORIG_SMIN_4=$(cat "$CPUFREQ/policy4/scaling_min_freq" 2>/dev/null)
ORIG_SMIN_7=$(cat "$CPUFREQ/policy7/scaling_min_freq" 2>/dev/null)
CB=/sys/module/cpu_boost/parameters
ORIG_CB_FREQ=$(cat "$CB/input_boost_freq" 2>/dev/null)
ORIG_CB_MS=$(cat "$CB/input_boost_ms" 2>/dev/null)
ORIG_CB_SBOI=$(cat "$CB/sched_boost_on_input" 2>/dev/null)

# ---------------- batas frekuensi per core ----------------
# cpuinfo_max <core> : frekuensi maksimum hardware core tsb (kHz)
cpuinfo_max() { cat "/sys/devices/system/cpu/cpu$1/cpufreq/cpuinfo_max_freq" 2>/dev/null; }
# cap_for <core> : batas freq yang boleh dipakai (per cluster dibatasi *_MAX).
# Nilai di-clamp ke hw max; 0 / kosong / > hw max = tanpa batas.
cap_for() {
	local hw cap
	hw=$(cpuinfo_max "$1")
	case "$1" in
		0|1|2|3) cap=$LITTLE_MAX ;;
		4|5|6)   cap=$MID_MAX ;;
		7)       cap=$PRIME_MAX ;;
		*)       cap= ;;
	esac
	if [ -n "$cap" ] && [ "$cap" -gt 0 ] 2>/dev/null && [ "$cap" -lt "${hw:-99999999}" ] 2>/dev/null; then
		echo "$cap"
	else
		echo "$hw"
	fi
}

# ---------------- CPU governor ----------------
cpu_gov() { # $1 = nama governor, atau "orig" untuk nilai stok
	local g=$1 d
	[ "$g" = "orig" ] && g=""
	for p in policy0 policy4 policy7; do
		d="$CPUFREQ/$p/scaling_governor"
		[ -w "$d" ] || continue
		if [ -n "$g" ]; then
			wr "$d" "$g"
		else
			case $p in
				policy0) wr "$d" "${ORIG_GOV0:-schedutil}" ;;
				policy4) wr "$d" "${ORIG_GOV4:-schedutil}" ;;
				policy7) wr "$d" "${ORIG_GOV7:-schedutil}" ;;
			esac
		fi
	done
}

# ---------------- CPU: kunci frekuensi maksimum ----------------
# game: scaling_min = scaling_max = cpuinfo_max_freq tiap cluster (anti frame-drop)
# idle: kembalikan ke nilai stok yang disimpan saat boot
cpu_lock() {
	local p fmax fmin mx
	for p in 0 4 7; do
		fmax="$CPUFREQ/policy$p/scaling_max_freq"
		fmin="$CPUFREQ/policy$p/scaling_min_freq"
		[ -w "$fmax" ] || continue
		if [ "$1" = "game" ]; then
			mx=$(cap_for "$p")
			[ -n "$mx" ] || continue
			# URUTAN PENTING: naikkan max DULU, baru min. Kalau min dinaikkan
			# lebih dulu, kernel meng-clamp-nya ke max lama (freq mentok).
			wr "$fmax" "$mx"
			wr "$fmin" "$mx"
		else
			case $p in
				0) [ -n "$ORIG_SMAX_0" ] && wr "$fmax" "$ORIG_SMAX_0"; [ -n "$ORIG_SMIN_0" ] && wr "$fmin" "$ORIG_SMIN_0" ;;
				4) [ -n "$ORIG_SMAX_4" ] && wr "$fmax" "$ORIG_SMAX_4"; [ -n "$ORIG_SMIN_4" ] && wr "$fmin" "$ORIG_SMIN_4" ;;
				7) [ -n "$ORIG_SMAX_7" ] && wr "$fmax" "$ORIG_SMAX_7"; [ -n "$ORIG_SMIN_7" ] && wr "$fmin" "$ORIG_SMIN_7" ;;
			esac
		fi
	done
}

# pastikan 8 core tetap online (cegah hotplug mematikan core saat game)
all_cores_online() {
	[ "$ALL_CORES_ONLINE" = "true" ] || return 0
	local c n
	for c in 0 1 2 3 4 5 6 7; do
		n="/sys/devices/system/cpu/cpu$c/online"
		[ -w "$n" ] && wr "$n" 1
	done
}

# ---------------- CPU input boost (cpu_boost) ----------------
# saat layar disentuh: semua core ke freq maks selama CPU_BOOST_MS
cpu_boost_set() {
	[ -r "$CB/input_boost_freq" ] || return 0
	if [ "$1" = "game" ] && [ "$CPU_BOOST_INPUT" = "true" ]; then
		local f="" c mx
		for c in 0 1 2 3; do mx=$(cap_for 0); f="$f$c:$mx "; done
		for c in 4 5 6; do mx=$(cap_for 4); f="$f$c:$mx "; done
		mx=$(cap_for 7); f="${f}7:$mx"
		wr "$CB/input_boost_freq" "$f"
		wr "$CB/input_boost_ms" "$CPU_BOOST_MS"
		[ "$SCHED_BOOST_ON_INPUT" = "true" ] && wr "$CB/sched_boost_on_input" 1
	else
		[ -n "$ORIG_CB_FREQ" ] && wr "$CB/input_boost_freq" "$ORIG_CB_FREQ"
		[ -n "$ORIG_CB_MS" ] && wr "$CB/input_boost_ms" "$ORIG_CB_MS"
		[ -n "$ORIG_CB_SBOI" ] && wr "$CB/sched_boost_on_input" "$ORIG_CB_SBOI"
	fi
}

# ---------------- GPU ----------------
# gpu_apply <min_pwrlevel> <governor> <force_clk 0/1> <idle_timer|''>
gpu_apply() {
	[ -w "$G/min_pwrlevel" ] && echo "$1" > "$G/min_pwrlevel" 2>/dev/null
	[ -n "$2" ] && [ -w "$G/devfreq/governor" ] && echo "$2" > "$G/devfreq/governor" 2>/dev/null
	if [ -w "$G/force_clk_on" ]; then
		echo "${3:-0}" > "$G/force_clk_on" 2>/dev/null
		echo "${3:-0}" > "$G/force_bus_on" 2>/dev/null
		echo "${3:-0}" > "$G/force_rail_on" 2>/dev/null
	fi
	[ -n "$4" ] && [ -w "$G/idle_timer" ] && echo "$4" > "$G/idle_timer" 2>/dev/null
}

# Kunci GPU ke clock tertinggi: pin devfreq min=max=max_gpuclk + min_pwrlevel=0.
# Membuat GPU benar-benar mentok di 770MHz (bukan cuma "boleh sampai").
gpu_lock_max() {
	local gmx
	gmx=$(cat "$G/max_gpuclk" 2>/dev/null)
	[ -n "$gmx" ] || return 0
	[ -w "$G/devfreq/max_freq" ] && echo "$gmx" > "$G/devfreq/max_freq" 2>/dev/null
	[ -w "$G/devfreq/min_freq" ] && echo "$gmx" > "$G/devfreq/min_freq" 2>/dev/null
	[ -w "$G/min_pwrlevel" ] && echo 0 > "$G/min_pwrlevel" 2>/dev/null
}
gpu_unlock_min() {
	[ -n "$ORIG_GPU_MIN_FREQ" ] && [ -w "$G/devfreq/min_freq" ] && echo "$ORIG_GPU_MIN_FREQ" > "$G/devfreq/min_freq" 2>/dev/null
	[ -n "$ORIG_GPU_MAX_FREQ" ] && [ -w "$G/devfreq/max_freq" ] && echo "$ORIG_GPU_MAX_FREQ" > "$G/devfreq/max_freq" 2>/dev/null
}

# ---------------- DDR / memory bandwidth ----------------
# Simpan nilai asli node devfreq DDR/LLCC/gpubw agar bisa dipulihkan saat idle.
build_ddr_list() {
	: > "$DDR_LIST"
	local n p mn mx gv
	for n in cpu-cpu-llcc-bw cpu-llcc-ddr-bw gpubw cpu0-llcc-ddr-lat cpu4-llcc-ddr-lat cpu4-cpu-ddr-latfloor; do
		p="/sys/class/devfreq/soc:qcom,$n"
		[ -d "$p" ] || continue
		mn=$(cat "$p/min_freq" 2>/dev/null)
		mx=$(cat "$p/max_freq" 2>/dev/null)
		gv=$(cat "$p/governor" 2>/dev/null)
		[ -n "$mx" ] || continue
		echo "$n|$mn|$mx|$gv" >> "$DDR_LIST"
	done
}

# game: naikkan floor bandwidth/latency DDR ke batas maksimum node.
# idle: pulihkan min/max/governor asli (urutan min dulu agar max tidak ter-clamp).
ddr_set() {
	[ -s "$DDR_LIST" ] || return 0
	local n omin omax ogov p mx
	while IFS='|' read -r n omin omax ogov; do
		[ -n "$n" ] || continue
		p="/sys/class/devfreq/soc:qcom,$n"
		[ -d "$p" ] || continue
		if [ "$1" = "game" ] && [ "$DDR_BOOST" = "true" ]; then
			mx=$(cat "$p/max_freq" 2>/dev/null)
			[ -n "$mx" ] && [ -w "$p/min_freq" ] && echo "$mx" > "$p/min_freq" 2>/dev/null
		else
			[ -n "$omin" ] && [ -w "$p/min_freq" ] && echo "$omin" > "$p/min_freq" 2>/dev/null
			[ -n "$omax" ] && [ -w "$p/max_freq" ] && echo "$omax" > "$p/max_freq" 2>/dev/null
			[ -n "$ogov" ] && [ -w "$p/governor" ] && echo "$ogov" > "$p/governor" 2>/dev/null
		fi
	done < "$DDR_LIST"
}

# ---------------- bypass charging ----------------
# on  : charging_enabled=0 -> HP ditenagai adaptor, baterai TIDAK diisi
#       (status jadi "Not charging", current_now ~0) -> panas jauh lebih rendah
# off : kembalikan pengisian normal (charging_enabled=1)
bypass_charge() {
	local want
	[ -w "$CHG_EN" ] || return 0
	if [ "$1" = "on" ]; then
		[ "$(cat "$USB_ON" 2>/dev/null)" = "1" ] || return 0
		want=0
	else
		want="${ORIG_CHG_EN:-1}"
	fi
	[ "$(cat "$CHG_EN" 2>/dev/null)" = "$want" ] || echo "$want" > "$CHG_EN" 2>/dev/null
}

# ---------------- touch (driver FTS) ----------------
# response boost: matikan filter glove/cover/charger + grip suppression saat game.
touch_set() {
	[ -d "$FTS" ] || return 0
	if [ "$1" = "game" ] && [ "$TOUCH_GAME" = "true" ]; then
		wr "$FTS/glove_mode" 0
		wr "$FTS/cover_mode" 0
		wr "$FTS/charger_mode" 0
	else
		[ -n "$ORIG_GLOVE" ] && wr "$FTS/glove_mode" "$ORIG_GLOVE"
		[ -n "$ORIG_COVER" ] && wr "$FTS/cover_mode" "$ORIG_COVER"
		[ -n "$ORIG_CHARGER" ] && wr "$FTS/charger_mode" "$ORIG_CHARGER"
	fi
	if [ "$1" = "game" ] && [ "$TOUCH_BOOST" = "true" ]; then
		wr "$FTS/grip_enable" "$TOUCH_GRIP_ENABLE"
		wr "$FTS/grip_area" "$TOUCH_GRIP_AREA"
	else
		[ -n "$ORIG_GRIP_ENABLE" ] && wr "$FTS/grip_enable" "$ORIG_GRIP_ENABLE"
		[ -n "$ORIG_GRIP_AREA" ] && wr "$FTS/grip_area" "$ORIG_GRIP_AREA"
	fi
}

# ---------------- network latency (game saja) ----------------
# Tuning tambahan yang hanya aktif saat game; nilai asli (hasil apply_static)
# dipulihkan saat idle sehingga tidak membebani pemakaian harian.
net_game_set() {
	[ "$EN_NET" = "true" ] || return 0
	if [ "$1" = "game" ] && [ "$NET_GAME_BOOST" = "true" ]; then
		wr /proc/sys/net/ipv4/tcp_notsent_lowat "$NET_NOTSOL_LOWAT"
		wr /proc/sys/net/ipv4/tcp_autocorking "$NET_AUTOCORKING"
		wr /proc/sys/net/ipv4/tcp_slow_start_after_idle "$NET_SLOW_START"
		wr /proc/sys/net/ipv4/tcp_no_metrics_save "$NET_NO_METRICS"
		wr /proc/sys/net/core/busy_poll "$NET_BUSY_POLL"
		wr /proc/sys/net/core/busy_read "$NET_BUSY_READ"
	else
		[ -n "$ORIG_NET_NOTSOL" ] && wr /proc/sys/net/ipv4/tcp_notsent_lowat "$ORIG_NET_NOTSOL"
		[ -n "$ORIG_NET_AUTOCORK" ] && wr /proc/sys/net/ipv4/tcp_autocorking "$ORIG_NET_AUTOCORK"
		[ -n "$ORIG_NET_SSAI" ] && wr /proc/sys/net/ipv4/tcp_slow_start_after_idle "$ORIG_NET_SSAI"
		[ -n "$ORIG_NET_METRICS" ] && wr /proc/sys/net/ipv4/tcp_no_metrics_save "$ORIG_NET_METRICS"
		[ -n "$ORIG_NET_BUSY_POLL" ] && wr /proc/sys/net/core/busy_poll "$ORIG_NET_BUSY_POLL"
		[ -n "$ORIG_NET_BUSY_READ" ] && wr /proc/sys/net/core/busy_read "$ORIG_NET_BUSY_READ"
	fi
}

# ---------------- sched latency (game: turunkan latensi) ----------------
sched_tune() {
	[ "$SCHED_TUNE" = "true" ] || return 0
	if [ "$1" = "game" ]; then
		wr /proc/sys/kernel/sched_latency_ns "$SCHED_LATENCY_NS"
		wr /proc/sys/kernel/sched_min_granularity_ns "$SCHED_MIN_GRA"
		wr /proc/sys/kernel/sched_wakeup_granularity_ns "$SCHED_WAKEUP_GRA"
	else
		[ -n "$ORIG_SCHED_LAT" ] && wr /proc/sys/kernel/sched_latency_ns "$ORIG_SCHED_LAT"
		[ -n "$ORIG_SCHED_MIN" ] && wr /proc/sys/kernel/sched_min_granularity_ns "$ORIG_SCHED_MIN"
		[ -n "$ORIG_SCHED_WAKE" ] && wr /proc/sys/kernel/sched_wakeup_granularity_ns "$ORIG_SCHED_WAKE"
	fi
}

# ---------------- msm_performance cpu_min_freq (floor per-core) ----------------
# format node: "0:<khz> 4:<khz> ...". Menulis sebagian cpu akan me-reset sisanya ke 0.
msmperf_min() {
	local p="$MSMPERF/cpu_min_freq"
	[ -w "$p" ] || return 0
	if [ "$1" = "game" ] && [ "${MSMPERF_MIN:-0}" -gt 0 ] 2>/dev/null; then
		echo "0:$MSMPERF_MIN 1:$MSMPERF_MIN 2:$MSMPERF_MIN 3:$MSMPERF_MIN 4:$MSMPERF_MIN 5:$MSMPERF_MIN 6:$MSMPERF_MIN 7:$MSMPERF_MIN" > "$p" 2>/dev/null
	else
		[ -n "$ORIG_MSMPERF" ] && echo "$ORIG_MSMPERF" > "$p" 2>/dev/null
	fi
}

# ---------------- thermal ----------------
build_thermal_list() {
	: > "$TZ_LIST"
	for z in /sys/class/thermal/thermal_zone*/; do
		z=${z%/}
		typ=$(cat "$z/type" 2>/dev/null)
		case "$typ" in
			gpuss-max-step) kind=gpu ;;
			cpu-0-0-step|cpu-1-0-step) kind=cpu ;;
			lmh-dcvs-00|lmh-dcvs-01) kind=lmh ;;
			*) continue ;;
		esac
		[ -w "$z/trip_point_0_temp" ] || continue
		orig=$(cat "$z/trip_point_0_temp" 2>/dev/null)
		[ -n "$orig" ] || continue
		echo "$kind|$z|$orig" >> "$TZ_LIST"
	done
}
thermal_set() {
	[ "$THERMAL_GAME" = "true" ] || return 0
	[ -s "$TZ_LIST" ] || return 0
	while IFS='|' read -r kind zone orig; do
		[ -n "$zone" ] || continue
		if [ "$1" = "game" ]; then
			[ "$kind" = "gpu" ] && echo "$GPU_TRIP_GAME" > "$zone/trip_point_0_temp" 2>/dev/null
			[ "$kind" = "cpu" ] && echo "$CPU_TRIP_GAME" > "$zone/trip_point_0_temp" 2>/dev/null
			[ "$kind" = "lmh" ] && [ "${LMH_TRIP_GAME:-0}" -gt 0 ] 2>/dev/null && echo "$LMH_TRIP_GAME" > "$zone/trip_point_0_temp" 2>/dev/null
		else
			echo "$orig" > "$zone/trip_point_0_temp" 2>/dev/null
		fi
	done < "$TZ_LIST"
}

# ---------- THERMAL UNLOCK ----------
# mi_thermald (Xiaomi) menimpa batas frekuensi tiap ~1s lewat cooling device.
# Hentikan dia + thermal-engine, lalu paksa tiap core ke frekuensi maksimum
# via thermal_message/cpu_limits (semantik: cpu_limits_set_level()).
# Proteksi darurat kernel (zona *-step, BCL, PMIC) tetap bekerja.
thermal_unlock_on() {
	stop mi_thermald 2>/dev/null
	stop vendor.thermal-engine 2>/dev/null
	# 1) lepas cap frekuensi CPU via thermal_message (semantik cpu_limits_set_level)
	if [ -w "$THERMAL_MSG/cpu_limits" ]; then
		local c m
		# WAJIB satu kali tulis (node = satu string); menulis per-baris akan
		# menimpa baris sebelumnya sehingga hanya core terakhir yang berlaku.
		{
			for c in 0 1 2 3 4 5 6 7; do
				m=$(cap_for "$c")
				[ -n "$m" ] && echo "cpu$c $m"
			done
		} > "$THERMAL_MSG/cpu_limits" 2>/dev/null
	fi
	# 2) lepas cap GPU: thermal_pwrlevel (0=770MHz .. naik=lebih lambat) +
	#    paksa devfreq max ke max_gpuclk. Tanpa ini GPU mentok 585/675MHz.
	[ -w "$G/thermal_pwrlevel" ] && echo 0 > "$G/thermal_pwrlevel" 2>/dev/null
	local gmx
	gmx=$(cat "$G/max_gpuclk" 2>/dev/null)
	[ -n "$gmx" ] && [ -w "$G/devfreq/max_freq" ] && echo "$gmx" > "$G/devfreq/max_freq" 2>/dev/null
}
thermal_unlock_off() {
	[ -n "$ORIG_THERMAL_PWRLEVEL" ] && [ -w "$G/thermal_pwrlevel" ] && echo "$ORIG_THERMAL_PWRLEVEL" > "$G/thermal_pwrlevel" 2>/dev/null
	[ -n "$ORIG_GPU_MAX_FREQ" ] && [ -w "$G/devfreq/max_freq" ] && echo "$ORIG_GPU_MAX_FREQ" > "$G/devfreq/max_freq" 2>/dev/null
	start mi_thermald 2>/dev/null
	start vendor.thermal-engine 2>/dev/null
}
# refresh cepat saat sudah di profil game (melawan thermal-engine bila respawn)
enforce_game() {
	if [ "$THERMAL_UNLOCK" = "true" ]; then
		[ -w "$G/thermal_pwrlevel" ] && echo 0 > "$G/thermal_pwrlevel" 2>/dev/null
		pgrep -x mi_thermald >/dev/null 2>&1 && stop mi_thermald 2>/dev/null
		pgrep -x thermal-engine >/dev/null 2>&1 && stop vendor.thermal-engine 2>/dev/null
		if [ -w "$THERMAL_MSG/cpu_limits" ]; then
			local c m
			{
				for c in 0 1 2 3 4 5 6 7; do
					m=$(cap_for "$c")
					[ -n "$m" ] && echo "cpu$c $m"
				done
			} > "$THERMAL_MSG/cpu_limits" 2>/dev/null
		fi
	else
		thermal_unlock_off
	fi
	[ "$CPU_LOCK_MAX" = "true" ] && cpu_lock game
	[ "$EN_GPU" = "true" ] && [ "$GPU_GAME_LOCK" = "true" ] && gpu_lock_max
	ddr_set game
	[ "$EN_BYPASS" = "true" ] && bypass_charge on
}

# ---------------- statis ----------------
# Simpan nilai asli node statis agar Mode Default bisa kembali 100% stok.
save_node() {
	local v
	v=$(cat "$1" 2>/dev/null)
	[ -n "$v" ] && echo "static|$1|$v" >> "$STATIC_LIST"
}
capture_static() {
	: > "$STATIC_LIST"
	local d s
	for d in /sys/block/sd* /sys/block/mmcblk*; do
		[ -d "$d/queue" ] || continue
		s=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$d/queue/scheduler" 2>/dev/null)
		[ -n "$s" ] && echo "io|$d/queue/scheduler|$s" >> "$STATIC_LIST"
		save_node "$d/queue/read_ahead_kb"
		save_node "$d/queue/nr_requests"
	done
	save_node /proc/sys/vm/vfs_cache_pressure
	save_node /proc/sys/vm/dirty_writeback_centisecs
	save_node /proc/sys/vm/swappiness
	save_node /proc/sys/vm/stat_interval
	save_node /proc/sys/vm/min_free_kbytes
	save_node /proc/sys/net/ipv4/tcp_low_latency
	save_node /proc/sys/net/ipv4/tcp_fastopen
	save_node /proc/sys/net/core/rmem_max
	save_node /proc/sys/net/core/wmem_max
	save_node /proc/sys/net/core/somaxconn
	save_node /proc/sys/net/ipv4/tcp_max_syn_backlog
	save_node /proc/sys/net/ipv4/tcp_rmem
	save_node /proc/sys/net/ipv4/tcp_wmem
	save_node /proc/sys/kernel/perf_cpu_time_max_percent
	save_node /proc/sys/fs/inotify/max_user_instances
	save_node /proc/sys/fs/inotify/max_user_watches
	save_node /proc/sys/fs/inotify/max_queued_events
}
restore_static() {
	[ -s "$STATIC_LIST" ] || return 0
	local v p kind
	while IFS='|' read -r kind p v; do
		[ -n "$p" ] || continue
		wr "$p" "$v"
	done < "$STATIC_LIST"
}
apply_static() {
	if [ "$EN_IO" = "true" ]; then
		local d
		for d in /sys/block/sd* /sys/block/mmcblk*; do
			[ -d "$d/queue" ] || continue
			wr "$d/queue/scheduler" "$IO_SCHED"
			wr "$d/queue/read_ahead_kb" "$IO_READAHEAD_KB"
			wr "$d/queue/nr_requests" "$IO_NR_REQUESTS"
		done
		log "io: sched=$IO_SCHED readahead=$IO_READAHEAD_KB"
	fi
	if [ "$EN_VM" = "true" ]; then
		wr /proc/sys/vm/vfs_cache_pressure "$VM_VFS"
		wr /proc/sys/vm/dirty_writeback_centisecs "$VM_DWC"
		wr /proc/sys/vm/swappiness "$VM_SWAPPINESS"
		wr /proc/sys/vm/stat_interval "$VM_STAT_INTERVAL"
		if [ -w /proc/sys/vm/min_free_kbytes ]; then
			local cur
			cur=$(cat /proc/sys/vm/min_free_kbytes 2>/dev/null)
			[ -n "$cur" ] && echo $((cur + VM_MIN_FREE_EXTRA)) > /proc/sys/vm/min_free_kbytes 2>/dev/null
		fi
		log "vm: vfs=$VM_VFS swappiness=$VM_SWAPPINESS"
	fi
	if [ "$EN_NET" = "true" ]; then
		wr /proc/sys/net/ipv4/tcp_low_latency "$NET_LL"
		wr /proc/sys/net/ipv4/tcp_fastopen "$NET_FASTOPEN"
		wr /proc/sys/net/core/rmem_max "$NET_RMEM"
		wr /proc/sys/net/core/wmem_max "$NET_WMEM"
		wr /proc/sys/net/core/somaxconn "$NET_SOMAXCONN"
		wr /proc/sys/net/ipv4/tcp_max_syn_backlog "$NET_BACKLOG"
		[ -n "$NET_TCP_RMEM" ] && echo "$NET_TCP_RMEM" > /proc/sys/net/ipv4/tcp_rmem 2>/dev/null
		[ -n "$NET_TCP_WMEM" ] && echo "$NET_TCP_WMEM" > /proc/sys/net/ipv4/tcp_wmem 2>/dev/null
		log "net: low_latency=$NET_LL fastopen=$NET_FASTOPEN somaxconn=$NET_SOMAXCONN"
	fi
	if [ "$EN_KERNEL" = "true" ]; then
		wr /proc/sys/kernel/perf_cpu_time_max_percent "$KERNEL_PERF"
		wr /proc/sys/fs/inotify/max_user_instances "$INOT_INST"
		wr /proc/sys/fs/inotify/max_user_watches "$INOT_WATCH"
		wr /proc/sys/fs/inotify/max_queued_events "$INOT_QUEUE"
		log "kernel: perf_cpu_time_max_percent=$KERNEL_PERF inotify=$INOT_WATCH"
	fi
}

# ---------------- profil ----------------
apply_game() {
	if [ "$EN_CPU" = "true" ]; then
		cpu_gov "$CPU_GAME_GOV"
		# PENTING: buka cap thermal (mi_thermald) SEBELUM mengunci frekuensi.
		# Tanpa ini, scaling_max ditahan di batas cooling (mis. 1.8GHz) dan
		# tokokan ke freq max tidak akan diterima.
		[ "$THERMAL_UNLOCK" = "true" ] && thermal_unlock_on || thermal_unlock_off
		[ "$CPU_LOCK_MAX" = "true" ] && cpu_lock game
		all_cores_online
		cpu_boost_set game
		wr /proc/sys/kernel/sched_boost 1
		wr "$STUNE/schedtune.boost" "$STUNE_BOOST"
	fi
	sched_tune game
	msmperf_min game
	ddr_set game
	[ "$EN_GPU" = "true" ] && gpu_apply "$GPU_GAME_FLOOR" "$GPU_GAME_GOV" "$GPU_FORCE_CLK" "$GPU_IDLE_TIMER"
	if [ "$EN_GPU" = "true" ]; then
		if [ "$GPU_GAME_LOCK" = "true" ]; then gpu_lock_max; else gpu_unlock_min; fi
	fi
	if [ "$EN_BYPASS" = "true" ]; then bypass_charge on; else bypass_charge off; fi
	net_game_set game
	thermal_set game
	touch_set game
	log "GAME: cpu=$CPU_GAME_GOV lock=$CPU_LOCK_MAX cap=$LITTLE_MAX/$MID_MAX/$PRIME_MAX gpu_floor=$GPU_GAME_FLOOR unlock=$THERMAL_UNLOCK bypass=$EN_BYPASS ddr=$DDR_BOOST touch=$TOUCH_BOOST net=$NET_GAME_BOOST"
}
apply_idle() {
	if [ "$EN_CPU" = "true" ]; then
		cpu_gov "$CPU_IDLE_GOV"
		[ "$CPU_LOCK_MAX" = "true" ] && cpu_lock idle
		cpu_boost_set idle
		wr /proc/sys/kernel/sched_boost 0
		wr "$STUNE/schedtune.boost" 0
	fi
	sched_tune idle
	msmperf_min idle
	ddr_set idle
	[ "$EN_GPU" = "true" ] && gpu_apply "$GPU_IDLE_FLOOR" "$GPU_IDLE_GOV" 0 "$ORIG_GPU_IDLE_TIMER"
	[ "$EN_GPU" = "true" ] && gpu_unlock_min
	net_game_set idle
	thermal_set idle
	touch_set idle
	thermal_unlock_off
	bypass_charge off
	log "IDLE: cpu=$CPU_IDLE_GOV gpu_floor=$GPU_IDLE_FLOOR"
}

# ---------------- mode default (stok ROM) ----------------
# Mode Default: tidak menerapkan tuning apa pun. Semua nilai dikembalikan ke
# aslinya (CPU, GPU, thermal, touch, net, DDR, I/O, VM, kernel).
apply_stock() {
	cpu_gov orig
	cpu_lock idle
	[ -n "$ORIG_CB_FREQ" ] && wr "$CB/input_boost_freq" "$ORIG_CB_FREQ"
	[ -n "$ORIG_CB_MS" ] && wr "$CB/input_boost_ms" "$ORIG_CB_MS"
	[ -n "$ORIG_CB_SBOI" ] && wr "$CB/sched_boost_on_input" "$ORIG_CB_SBOI"
	wr /proc/sys/kernel/sched_boost 0
	wr "$STUNE/schedtune.boost" 0
	sched_tune idle
	msmperf_min idle
	ddr_set idle
	gpu_apply "${ORIG_GPU_PWRLEVEL:-6}" "${ORIG_GPU_GOV:-msm-adreno-tz}" 0 "${ORIG_GPU_IDLE_TIMER:-}"
	gpu_unlock_min
	net_game_set idle
	thermal_set idle
	touch_set idle
	thermal_unlock_off
	bypass_charge off
	restore_static
	log "DEFAULT: stok ROM (tanpa tuning)"
}

# ---------------- inisialisasi ----------------
capture_static
build_ddr_list
build_thermal_list
ORIG_NET_NOTSOL=$(cat /proc/sys/net/ipv4/tcp_notsent_lowat 2>/dev/null)
ORIG_NET_AUTOCORK=$(cat /proc/sys/net/ipv4/tcp_autocorking 2>/dev/null)
ORIG_NET_SSAI=$(cat /proc/sys/net/ipv4/tcp_slow_start_after_idle 2>/dev/null)
ORIG_NET_METRICS=$(cat /proc/sys/net/ipv4/tcp_no_metrics_save 2>/dev/null)
ORIG_NET_BUSY_POLL=$(cat /proc/sys/net/core/busy_poll 2>/dev/null)
ORIG_NET_BUSY_READ=$(cat /proc/sys/net/core/busy_read 2>/dev/null)
log "ddr: $(wc -l < "$DDR_LIST" 2>/dev/null) node target"
log "thermal: $(wc -l < "$TZ_LIST" 2>/dev/null) zone target"

# baseline: default/global = stok ROM; gaming = idle
if [ "$MODE" = "global" ]; then
	apply_stock
	state=global
else
	apply_static
	apply_idle
	state=idle
fi

# FAILSAFE: kalau sampai di sini + sistem tetap hidup 45 detik, anggap boot
# sukses -> reset counter (sehingga tidak ke-disable setelah 3 boot normal).
sleep 45
rm -f "$BOOTCOUNT" 2>/dev/null
log "boot marked OK (failsafe counter reset)"

# ---------------- main loop ----------------
while :; do
	# muat ulang konfigurasi bila WebUI men-*touch* .reload
	if [ -f "$RELOAD" ]; then
		rm -f "$RELOAD"
		load_config
		sanitize_governors
		if [ "$MODE" = "global" ]; then
			apply_stock; state=global
		else
			apply_static
			if game_active; then
				apply_game; state=game
			else
				apply_idle; state=idle
			fi
		fi
		log "reload: konfigurasi dibaca ulang (mode=$MODE)"
	fi

	if [ "$MODE" = "global" ]; then
		if [ "$state" != "global" ]; then
			apply_stock
			state=global
		fi
	elif game_active; then
		if [ "$state" != "game" ]; then
			apply_game
			state=game
		else
			# tetap di profil game -> reinforce (thermal-engine bisa respawn)
			enforce_game
		fi
	else
		if [ "$state" != "idle" ]; then
			apply_idle
			state=idle
		fi
	fi
	sleep "$GP_POLL"
done
