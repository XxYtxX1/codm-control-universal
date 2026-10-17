#!/system/bin/sh
SKIPUNZIP=0
ui_print "- CODM Ultra Stretch v1.16-universal (companion app + stretch + CPU/GPU + FPS)"
. "$MODPATH/common.sh"
mkdir -p "$DIR"
load_cfg
write_cfg
ui_print "- Config: $DIR/config.conf"

set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in service.sh api.sh fps.sh cpu_gpu.sh sysinfo.sh action.sh uninstall.sh; do
  set_perm "$MODPATH/$f" 0 0 0755
done
set_perm "$MODPATH/webroot/cgi-bin/api.cgi" 0 0 0755
set_perm_recursive "$MODPATH/system" 0 0 0755 0644

if [ -f "$MODPATH/system/app/CODMControl/CODMControl.apk" ]; then
  set_perm "$MODPATH/system/app/CODMControl/CODMControl.apk" 0 0 0644
  ui_print "- CODM Control companion app will be mounted as a systemless system app"
else
  ui_print "- Companion APK not bundled; install CODM_Control.apk manually if needed"
fi

ui_print "- Reboot, then open the WebUI or CODM Control app:"
ui_print "    KernelSU / MMRL : module WebUI button"
ui_print "    Magisk          : Action button, or http://127.0.0.1:$WEBUI_PORT"
ui_print "- On-screen FPS counter: installs the CODM FPS overlay app on first boot"
ui_print "- Open CODM after reboot. All settings live in the WebUI"
