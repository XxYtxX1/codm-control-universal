#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/common.sh"
[ -f "$DIR/web.pid" ] && kill "$(cat "$DIR/web.pid")" 2>/dev/null
[ -f "$DIR/fps.pid" ] && kill "$(cat "$DIR/fps.pid")" 2>/dev/null
[ -f "$DIR/service.pid" ] && kill "$(cat "$DIR/service.pid")" 2>/dev/null
[ -f "$ACTIVE" ] && do_restore
[ -f "$FPSACT" ] && { load_cfg; fps_restore; }
[ -f "$OVLACT" ] && ovl_off
rm -f "$HOOK_OFF"
[ -f "$DIR/ovl_install.txt" ] && { am force-stop com.codm.fps; pm uninstall com.codm.fps >/dev/null 2>&1; }
rm -rf "$DIR"
