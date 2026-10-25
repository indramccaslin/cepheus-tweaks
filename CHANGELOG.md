# Changelog

## v1.0.1 (versionCode 10001)
- **Rilis penyelaras** — zip rilis diselaraskan dengan source `main`; sebelumnya aset `v1.0.0` sudah memuat perubahan ini tetapi tag masih di commit lama.
- **Mode Default (global) murni stok ROM** — tidak ada tuning CPU/GPU/thermal/I/O/VM/net/kernel dan semua nilai asli dipulihkan; mode ini aktif secara default saat modul dipasang.
- **Metadata author** — author modul diset ke **GANÉS**.

## v1.0.0 (versionCode 10000)
- **Skema versi baru** — penomoran versi direset ke 1.0.0; riwayat versi lama di bawah dipertahankan.
- **Mode Default (stok ROM)** — mode `global` kini benar-benar stok: tidak ada tuning CPU/GPU/thermal/I/O/VM/net/kernel dan semua nilai asli dipulihkan. Mode ini menjadi default saat modul dipasang.
- **Touch Response Boost** — saat game, filter grip/glove/cover/charger dimatikan agar sentuhan lebih responsif; nilai asli dipulihkan saat idle. Input-boost CPU tetap aktif.
- **Network Boost** — tuning latensi TCP hanya saat game: `tcp_notsent_lowat`, autocorking off, slow-start-after-idle off, no metrics save, busy polling. Semua dipulihkan saat idle.
- **DDR Boost** — floor bandwidth/latency DDR, LLCC, dan GPU bus dinaikkan ke maksimum selama game lalu dipulihkan saat idle.
- **WebUI baru** — hero dashboard dengan status pill, kartu **Optimasi Game** berisi toggle Touch/Network/DDR/GPU/Thermal/Bypass, tema gelap glassmorphism, animasi halus, dan switch modern.
- **Perbaikan WebUI** — label aplikasi sistem pada app picker, fallback daftar aplikasi sistem, dan status governor/frekuensi di dashboard.

## v3.6.0 (versionCode 30060)
- **Tanpa Encore** — integrasi dan jalur deteksi Encore dihapus; modul berdiri sendiri sepenuhnya.
- **Pemilih governor di WebUI** — kartu **Governor** baru: CPU (game/idle) dan GPU (game/idle) dengan daftar governor yang tersedia kernel, deskripsi singkat, dan terapkan langsung (reload otomatis).
- **Sanitasi governor** — `service.sh` memvalidasi governor dari `tweak.conf` terhadap `scaling_available_governors`/`available_governors`, fallback aman bila nilai tidak didukung.
- **WebUI & modul diperbarui** — teks, versi module.prop, update.json, dan customize.sh disesuaikan.

## v3.5.0 (versionCode 30050)
- **Semua frekuensi tersedia di WebUI** — tabel Little / Mid / Prime kini menampilkan **seluruh** step frekuensi yang dilaporkan kernel (`scaling_available_frequencies`), dibaca dinamis dari `/sys/devices/system/cpu/cpufreq/policy{0,4,7}`. Ada penanda *Maksimum (stok)* dan *Minimum*, serta fallback statis bila node tidak terbaca.
- **Expand/collapse per cluster** — kartu Little / Mid / Prime dapat diklik untuk membuka/menutup daftar frekuensi; header menampilkan frekuensi terpilih. Status buka diingat per cluster (localStorage).
- **Teks WebUI lebih profesional** — seluruh penjelasan (mode, CPU, daftar game, pengaturan) ditulis ulang agar lebih jelas dan teknis.
- **Pengaturan: ganti bahasa** — kartu baru **Pengaturan** hanya berisi pemilih bahasa **Bahasa Indonesia / English**; seluruh teks WebUI mengikuti pilihan tersebut dan tersimpan di localStorage.

## v3.4.0 (versionCode 30040)
- **Mode Global / Gaming (WebUI baru)** — pemilih mode di paling atas:
  - **Global** — HANYA batas frekuensi CPU (`*_MAX`) yang aktif, dan **berlaku terus** (siaga & game). Semua fitur lain dimatikan/dipulihkan ke stok. Cocok untuk harian (adem/hemat baterai).
  - **Gaming** — profil lengkap (CPU/GPU/thermal/bypass charging/tuning) aktif otomatis saat game dibuka (perilaku sebelumnya).
  - Disimpan sebagai `MODE=gaming|global` di `tweak.conf`. `service.sh` punya `apply_global`/`enforce_global` (re-enforce ringan hanya bila `scaling_max` naik di atas cap; tidak melawan proteksi thermal).
- **Tampilan WebUI dirombak** — tema gelap modern, gradien, ikon SVG inline (mode/CPU/daftar game), kartu mode dapat diketuk, chip frekuensi aktif per cluster.
- **Daftar Game expand/collapse** — header dapat diketuk untuk buka/tutup; ada badge jumlah game; status buka diingat (localStorage). Daftar game hanya tampil di Mode Gaming.

## v3.3.1 (versionCode 30031)
- **Kontrol throttle LMH (hardware) via WebUI/conf** — opsi baru `LMH_TRIP_GAME` (default `95000` = 95°C). Saat game, trip zona `lmh-dcvs-00`/`lmh-dcvs-01` (stok 85°C) dinaikkan agar LMH mulai lebih lambat; dipulihkan ke nilai stok saat idle. `0` = jangan diubah.
- Zona `lmh-dcvs` ditambahkan ke `build_thermal_list` (kind `lmh`) sehingga trip-nya di-backup & di-restore otomatis.
- Catatan: batas keras LMH sejati (sensor isens/tegangan di silikon) + BCL tetap aktif dan tidak bisa dimatikan dari userspace (butuh patch kernel/DT `qcom,plat-mitigation-disable`).

## v3.3.0 (versionCode 30030)
- **Frekuensi CPU per cluster (WebUI)** — 3 tabel di paling atas WebUI (Little / Mid / Prime), masing-masing **4** pilihan batas frekuensi maksimum saat game:
  - **Little (core 0-3)** — 1.785 / 1.709 / 1.555 / 1.306 GHz
  - **Mid (core 4-6)** — 2.419 / 2.131 / 2.016 / 1.805 GHz
  - **Prime (core 7)** — 2.841 / 2.650 / 2.419 / 2.131 GHz
  Menurunkan frekuensi sering justru menaikkan GIPS *sustained* (throttle LMH mulai lebih lambat).
- Config baru `LITTLE_MAX` / `MID_MAX` / `PRIME_MAX` (kHz). Dipakai oleh `cpu_lock`, `thermal_unlock`/`cpu_limits`, input-boost `cpu_boost`, dan `enforce_game`. Nilai di-clamp ke hw max; `0`/kosong/>hw max = tanpa batas.
- Log GAME kini menampilkan `cap=<little>/<mid>/<prime>`.

## v3.2.6 (versionCode 30026)
- **Standalone** — no longer needs Encore Tweaks or any other daemon.
- **WebUI** (KernelSU-Next Manager) to manage the game list. Fixed the app picker: `ksu.exec()` (sync) only returns the *last* line, so the WebUI now uses `ksu.listPackages()` for the app list and reads the multi-line `gamelist.txt` in a single-line-safe way.
- **CPU max lock**: all three clusters pinned to `performance` + `scaling_min = scaling_max = cpuinfo_max_freq` while a game is in foreground.
- **GPU lock at 770 MHz**: pins `min_freq = max_freq = max_gpuclk` and `min_pwrlevel = 0` during games (`GPU_GAME_LOCK`).
- **Thermal unlock**: stops `mi_thermald` + opens `thermal_message/cpu_limits` and the GPU cooling clamp during games; restored on idle.
- **Bypass charging**: keeps the phone powered by the adapter (battery `current_now ≈ 0`, cooler) while gaming.
- **Scheduler / input boost / schedtune** tuning for stable 60 fps.
- **Boot-safe**: runs via `service.sh` with a boot-count failsafe (auto-disables after repeated failed boots).
- Config `GP_POLL` (game detection interval, default 2 s).

## v2.0.0 (versionCode 3)
- **Merged** `cepheus-thermal-nolimits` + `cepheus-gaming-tweaks` into a single module.
- **Dynamic thermal**: userspace thermal throttling is released *only during games* — the `mi_thermald` daemon is `SIGSTOP`-ed, cooling devices are reset, and the CPU `scaling_max_freq` clamp is opened. Once the game is closed, the daemon is resumed (normal thermal again).
- Guard: if the daemon is restarted by the system during a game, it is paused again automatically.
- Dynamic GPU floor (game 4 / idle 6), I/O `deadline`, VM cache pressure & dirty writeback.
- Added `update.json` for the KernelSU update checker.

## v1.1.0 (versionCode 2)
- Dynamic GPU floor based on Encore's game state.
- I/O scheduler + VM tweaks.

## v1.0.0 (versionCode 1)
- Initial release: static GPU floor, I/O, VM.
