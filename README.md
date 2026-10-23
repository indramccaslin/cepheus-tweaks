# Cepheus Tweaks

A **standalone** KernelSU-Next (and Magisk) module that automatically locks the **CPU and GPU to maximum performance while a game is in the foreground** — stable 60 fps and anti frame-drop — for the **Xiaomi Mi 9 (cepheus, sm8150)**. Outside games the system runs normally, with no extra daemon required.

It ships with a **WebUI** (KernelSU-Next Manager) dashboard to manage the game list, mode, frequency caps, governors and optimization toggles.

## Features

- **Automatic game/idle profiles** — detects the foreground game (~2 s) and switches profiles.
- **CPU max lock** — all clusters → `performance` governor, plus `scaling_min_freq = scaling_max_freq = cpuinfo_max_freq`.
- **Per-cluster frequency caps** — choose Little / Mid / Prime maximum frequencies from the WebUI.
- **Governor picker** — CPU and GPU governor for game and idle, read from the kernel's available governor list.
- **GPU lock** — pinned at **770 MHz** (`min_freq = max_freq = max_gpuclk`, `min_pwrlevel = 0`).
- **Touch response boost** — disables glove/cover/charger modes and grip suppression during games.
- **Network boost** — lowers TCP latency during games (`tcp_notsent_lowat`, autocorking off, slow-start-after-idle off, no metrics save, busy polling); restored on idle.
- **DDR boost** — raises the DDR / LLCC / GPU-bus bandwidth and latency floor to maximum during games, then restores idle values.
- **Thermal unlock** — stops `mi_thermald` and opens `thermal_message/cpu_limits` + the GPU cooling clamp during games; restored on idle. Kernel emergency protection (BCL, `*-step` zones, LMH) stays active.
- **Bypass charging** — while gaming the phone runs off the adapter (battery `current_now ≈ 0`, cooler).
- **Scheduler / input boost / schedtune** tuning for steadier frame pacing.
- **Boot-safe** — runs from `service.sh` with a boot-count failsafe (auto-disables after repeated failed boots).

## Requirements

- Xiaomi Mi 9 — `cepheus` / `sm8150`.
- KernelSU-Next (3.4.x) or Magisk.
- A kernel exposing the `thermal_message`, `kgsl` and `msm_performance` nodes (the stock Xiaomi kernel does).

## Install

1. Download `Cepheus-Tweaks-vX.Y.Z.zip` from [Releases](../../releases).
2. KernelSU-Next / Magisk Manager → **Modules** → **Install from storage** → pick the zip.
3. Reboot.

The module also exposes `update.json` so the manager can check for updates.

## Usage (WebUI)

Manager → **Modules** → **Cepheus Tweaks** → **WebUI**:

- **Mode** — Default (pure ROM stock, no tweaks applied) or Gaming (full profile while a game is active). Default is used on first install.
- **CPU frequency** — pick the maximum frequency for Little / Mid / Prime.
- **Governor** — pick CPU/GPU governors for game and idle.
- **Optimasi Game** — toggle Touch Response, Network Boost, DDR Boost, GPU Max Lock, Thermal Unlock and Bypass Charging.
- **Daftar Game** — add/remove packages. Type the package name manually or tap
  **Pilih dari daftar aplikasi** to pick from the installed apps.

Every change is written to `tweak.conf`/`gamelist.txt` and the worker reloads
within ~5 s — **no reboot needed**.

## Configuration

Everything lives in `/data/adb/modules/cepheus-tweaks/tweak.conf` (also editable from the WebUI):

| Key | Default | Description |
|---|---|---|
| `GP_CPU` / `GP_GPU` / `GP_IO` / `GP_VM` / `GP_NET` / `GP_KERNEL` | `true` | Master switches per subsystem |
| `GP_DYNAMIC` | `true` | `false` = apply the game profile permanently (not recommended) |
| `GP_POLL` | `2` | Game-detection interval (seconds) |
| `CPU_GAME_GOV` / `CPU_IDLE_GOV` | `performance` / `schedutil` | CPU governor for game / idle |
| `CPU_LOCK_MAX` | `true` | Pin `scaling_min = scaling_max = max` during games |
| `GPU_GAME_PWRLEVEL` / `GPU_IDLE_PWRLEVEL` | `0` / `6` | GPU power level (`0` = max clock) |
| `GPU_GAME_GOV` / `GPU_IDLE_GOV` | `performance` / `msm-adreno-tz` | GPU governor |
| `GPU_GAME_LOCK` | `true` | Lock GPU at 770 MHz during games |
| `GPU_FORCE_CLK` / `GPU_IDLE_TIMER` | `1` / `200` | Hold the max rail / idle timer |
| `THERMAL_UNLOCK` | `true` | Stop userspace thermal daemons during games |
| `GP_BYPASS_CHARGE` | `true` | Bypass charging during games |
| `TOUCH_BOOST` | `true` | Disable grip suppression during games |
| `NET_GAME_BOOST` | `true` | Extra TCP latency tuning during games |
| `NET_NOTSOL_LOWAT` / `NET_BUSY_POLL` / `NET_BUSY_READ` | `16384` / `50` / `50` | Network boost values |
| `DDR_BOOST` | `true` | Raise DDR/LLCC/GPU-bus floor during games |

(`min_pwrlevel`: lower number = higher clock.)

## Verify

While a game is running:

```sh
# CPU governor (expect "performance" on every cluster)
for p in 0 4 7; do cat /sys/devices/system/cpu/cpufreq/policy$p/scaling_governor; done

# GPU (expect 770000000)
cat /sys/class/kgsl/kgsl-3d0/devfreq/cur_freq

# thermal daemon paused ("T") + GPU cooling released (tp=0)
awk '{print $3}' /proc/$(pidof mi_thermald)/stat
cat /sys/class/kgsl/kgsl-3d0/thermal_pwrlevel
```

Log: `/data/adb/modules/cepheus-tweaks/tweak.log`.

## Disable / Uninstall

- Temporarily disable: create `/data/adb/modules/cepheus-tweaks/disable`.
- Uninstall: remove the folder (or via the manager). `uninstall.sh` restores the
  governor, GPU, scheduler and restarts the thermal daemons.

## Notes

- Thermal unlock removes Xiaomi's userspace limit during games, so the phone gets
  **hotter** and drains faster. Kernel protections remain, but avoid long gaming
  sessions while charging.
- If it gets too hot, set `THERMAL_UNLOCK=false` and/or raise
  `GPU_GAME_PWRLEVEL`.

## License

[MIT](LICENSE)
