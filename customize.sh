#!/system/bin/sh
# customize.sh - dijalankan otomatis saat modul dipasang (KernelSU-Next / Magisk)

# Fallback bila ui_print tak disediakan installer
command -v ui_print >/dev/null 2>&1 || ui_print() { echo "  $1"; }

ui_print " "
ui_print "  #####################################"
ui_print "  #        CEPHEUS TWEAKS  v1.0.1      #"
ui_print "  #   Xiaomi Mi 9 (cepheus/sm8150)    #"
ui_print "  #####################################"
ui_print " "
ui_print "  Mengunci CPU & GPU ke performa"
ui_print "  maksimum OTOMATIS saat game dibuka."
ui_print " "
ui_print "  CARA PAKAI:"
ui_print "  1. Buka tab WebUI di aplikasi manager."
ui_print "  2. Tambahkan game kamu (nama paket)."
ui_print "  3. Selesai. Buka game -> otomatis ngebut."
ui_print "     Tutup game -> balik hemat daya."
ui_print " "
ui_print "  SAAT GAME AKTIF:"
ui_print "  - CPU: semua core dikunci di frekuensi max"
ui_print "  - GPU: clock maksimum, rail/clk ditahan"
ui_print "  - Scheduler & input-boost -> anti frame-drop"
ui_print "  - Limit thermal dibuka (anti throttle)"
ui_print " "
ui_print "  PERINGATAN:"
ui_print "  Frekuensi maksimal = HP lebih PANAS &"
ui_print "  baterai lebih boros saat main game."
ui_print " "
ui_print "  - Mengatur izin file..."
ui_print " "

[ -n "$MODPATH" ] || MODPATH="$(dirname "$0")"

for f in service.sh uninstall.sh; do
  [ -f "$MODPATH/$f" ] && chmod 0755 "$MODPATH/$f" 2>/dev/null
  command -v set_perm >/dev/null 2>&1 && set_perm "$MODPATH/$f" 0 0 0755 2>/dev/null
done
for f in module.prop tweak.conf gamelist.txt README.md; do
  [ -f "$MODPATH/$f" ] && chmod 0644 "$MODPATH/$f" 2>/dev/null
done
[ -f "$MODPATH/webroot/index.html" ] && chmod 0644 "$MODPATH/webroot/index.html" 2>/dev/null

ui_print "  - Selesai! Reboot lalu buka WebUI,"
ui_print "    tekan 'Pilih dari daftar aplikasi',"
ui_print "    pilih game, lalu Simpan."
ui_print " "
