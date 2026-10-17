#!/system/bin/sh
SKIPUNZIP=0
ui_print "- CODM Ultra Stretch v1.14 (App + stretch + CPU/GPU control + FPS monitor)"
. "$MODPATH/common.sh"
mkdir -p "$DIR"
load_cfg      # keeps settings from older versions and fills in new ones
write_cfg
ui_print "- Config: $DIR/config.conf"

set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in service.sh api.sh fps.sh cpu_gpu.sh action.sh uninstall.sh; do set_perm "$MODPATH/$f" 0 0 0755; done
set_perm "$MODPATH/webroot/cgi-bin/api.cgi" 0 0 0755
set_perm_recursive "$MODPATH/system" 0 0 0755 0644
[ -f "$MODPATH/system/app/CODMControl/CODMControl.apk" ] && set_perm "$MODPATH/system/app/CODMControl/CODMControl.apk" 0 0 0644

ui_print "- CODM Control app is installed as a system app after reboot (if APK is bundled)."
ui_print "- Reboot, then open the WebUI or CODM Control app:"
ui_print "    KernelSU/MMRL: module's WebUI button"
ui_print "    Magisk: Action button, or http://127.0.0.1:$WEBUI_PORT"
ui_print "- On-screen FPS counter: installs the CODM FPS overlay app on first boot"
ui_print "- Reboot, then open CODM. Settings are in the WebUI"
