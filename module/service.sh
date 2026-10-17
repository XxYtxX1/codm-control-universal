#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/common.sh"

mkdir -p "$DIR"
chmod 0755 "$MODDIR/api.sh" "$MODDIR/fps.sh" "$MODDIR/webroot/cgi-bin/api.cgi" 2>/dev/null

while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 3; done
sleep "${CODM_BOOT_WAIT:-8}"

load_cfg
sync_fill
# Safety: if we rebooted while something was applied, put everything back first
[ -f "$ACTIVE" ] && do_restore
[ -f "$FPSACT" ] && fps_restore
[ -f "$DIR/.cpugpu_snapshot" ] && sh "$MODDIR/cpu_gpu.sh" restore
[ -f "$OVLACT" ] && ovl_off
overlay_stop
rm -f "$TESTF" "$RESETF" "$LOCKTESTF" "$DIR/test_size" "$INGF" "$LIVE" "$HIST" "$SESS"
echo $$ > "$DIR/service.pid"

PHYS=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  PHYS=$(phys_size); [ -n "$PHYS" ] && break; sleep 3
done
echo "$PHYS" > "$DIR/phys"
phys_dens > "$DIR/phys_dens"
save_rates
log "service started, panel=$PHYS, model=$(getprop ro.product.model), android=$(getprop ro.build.version.release), refresh rates: $(cat "$RATES" 2>/dev/null)"

# ---- localhost web server for the WebUI (Magisk has no WebUI of its own)
find_httpd() {
  for b in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox "$(command -v busybox)"; do
    [ -n "$b" ] && [ -x "$b" ] && "$b" --list 2>/dev/null | grep -qx httpd && { echo "$b"; return 0; }
  done
  return 1
}
start_web() {
  [ "$WEBSERVER" = "1" ] || { log "web server disabled in config"; return; }
  [ -f "$DIR/web.pid" ] && kill "$(cat "$DIR/web.pid")" 2>/dev/null
  rm -f "$DIR/web.pid"
  B=$(find_httpd) || { log "no busybox httpd found - WebUI only via KernelSU/MMRL"; return; }
  "$B" httpd -f -p "127.0.0.1:$WEBUI_PORT" -h "$MODDIR/webroot" >/dev/null 2>&1 &
  echo $! > "$DIR/web.pid"
  sleep 1
  if kill -0 "$(cat "$DIR/web.pid")" 2>/dev/null; then
    log "WebUI: http://127.0.0.1:$WEBUI_PORT"
  else
    log "httpd failed to start (port $WEBUI_PORT busy?)"; rm -f "$DIR/web.pid"
  fi
}
start_web

# ---- on-screen FPS overlay app (install once, grant overlay permission)
overlay_install "$MODDIR" && log "overlay app ready ($OVL_PKG)" || log "overlay app NOT installed - see 'overlay install' line above"

# ---- real FPS sampler (idle until the game is on screen)
[ -f "$DIR/fps.pid" ] && kill "$(cat "$DIR/fps.pid")" 2>/dev/null
sh "$MODDIR/fps.sh" >/dev/null 2>&1 &
echo $! > "$DIR/fps.pid"

# ---- game detection
game_running() {
  for p in $PACKAGES; do pidof "$p" >/dev/null 2>&1 && return 0; done
  return 1
}
# Is the game the app on screen?  FGM=1 yes, 0 no, 2 could not tell.
# One cheap query first; the heavy full window dump only when that one does not show the game.
fg_check() {
  FGM=0
  _a=$(dumpsys activity activities 2>/dev/null | grep -E 'topResumedActivity|ResumedActivity' | head -n 3)
  for p in $PACKAGES; do case "$_a" in *"$p"*) FGM=1;; esac; done
  [ $FGM -eq 1 ] && return
  _w=$(dumpsys window 2>/dev/null | grep -m1 mCurrentFocus)
  for p in $PACKAGES; do case "$_w" in *"$p"*) FGM=1;; esac; done
  [ $FGM -eq 0 ] && [ -z "$_a$_w" ] && FGM=2
}

CGA=""        # applied CPU/GPU profile
OVLRS=0        # last time the overlay app was (re)started
STR=0          # 1 = stretch applied by us
APPLIED=""     # what we applied (size/density)
FPSA=""        # legacy FPS lock disabled
OVL=0          # 1 = system refresh-rate overlay on
OV2=""         # what the FPS overlay app was started with
INGAME=0       # 1 = game on screen (after grace)
MISS=0; SINCE=0; SUPPRESS=0
set_status idle ""

while true; do
  load_cfg
  sync_fill
  NOW=$(date +%s)

  # "Restore now" pressed in the WebUI: stay off until the game is closed once
  if [ -f "$RESETF" ]; then
    rm -f "$RESETF" "$TESTF"
    [ -f "$ACTIVE" ] && do_restore
    [ $INGAME -eq 1 ] && SUPPRESS=1
    STR=0; APPLIED=""; set_status idle ""
    log "manual restore"
  fi

  # "Test" pressed in the WebUI: hold the test size until it expires
  if [ -f "$TESTF" ]; then
    UNTIL=$(cat "$TESTF" 2>/dev/null)
    if [ "$NOW" -lt "${UNTIL:-0}" ] 2>/dev/null; then
      STR=2; set_status test "$(cat "$DIR/test_size" 2>/dev/null)"
      sleep 1; continue
    fi
    rm -f "$TESTF" "$DIR/test_size"
    do_restore; STR=0; APPLIED=""; set_status idle ""
    log "test ended"
  fi

  # "Test lock" pressed in the WebUI: hold the refresh-rate lock until it expires
  if [ -f "$LOCKTESTF" ]; then
    UNTIL=$(cat "$LOCKTESTF" 2>/dev/null)
    if [ "$NOW" -lt "${UNTIL:-0}" ] 2>/dev/null; then sleep 1; continue; fi
    rm -f "$LOCKTESTF"
    fps_restore; FPSA=""
    log "lock test ended"
  fi

  # ---- is the game on screen?
  IN=0
  if game_running; then
    fg_check
    case $FGM in
      1) IN=1;;
      2) [ $INGAME -eq 1 ] && IN=1;;   # can't tell -> keep current state
    esac
  fi

  if [ $IN -eq 1 ]; then
    MISS=0
    if [ $INGAME -eq 0 ]; then
      INGAME=1; SINCE=$NOW; : > "$INGF"; log "game on screen"
    fi
  else
    [ $MISS -lt 30 ] && MISS=$((MISS + 1))
    if [ $INGAME -eq 1 ] && [ $MISS -ge "$RESTORE_GRACE" ]; then
      INGAME=0; SUPPRESS=0; rm -f "$INGF"; log "game left"
    fi
  fi

  READY=0
  [ $INGAME -eq 1 ] && [ $(( NOW - SINCE )) -ge "$APPLY_DELAY" ] && READY=1

  # ---- stretch
  if [ "$ENABLED" = "1" ] && [ $READY -eq 1 ] && [ $SUPPRESS -eq 0 ]; then
    T=$(calc_size)
    if [ -n "$T" ]; then
      D=$(calc_density); KEY="$T/$D"
      if [ $STR -eq 0 ] || [ "$KEY" != "$APPLIED" ]; then
        apply_cfg "$T"; STR=1; APPLIED="$KEY"; set_status game "$T"
        log "applied $T${D:+ @ ${D}dpi}"
      fi
    fi
  elif [ $STR -eq 1 ] && { [ $INGAME -eq 0 ] || [ "$ENABLED" != "1" ]; }; then
    do_restore; STR=0; APPLIED=""; set_status idle ""; log "stretch restored"
  fi

  # ---- CPU/GPU frequency ceiling: only while CODM is foreground and ready
  if [ "$CPU_GPU_ENABLED" = "1" ] && [ $READY -eq 1 ]; then
    CGKEY="$CPU_GPU_PROFILE"
    if [ "$CGKEY" != "$CGA" ]; then
      sh "$MODDIR/cpu_gpu.sh" apply
      CGA="$CGKEY"
    fi
  elif [ -n "$CGA" ] && { [ $INGAME -eq 0 ] || [ "$CPU_GPU_ENABLED" != "1" ]; }; then
    sh "$MODDIR/cpu_gpu.sh" restore; CGA=""
  fi

  # ---- system refresh-rate overlay
  if [ "$SF_OVERLAY" = "1" ] && [ $INGAME -eq 1 ]; then
    [ $OVL -eq 0 ] && { ovl_on; OVL=1; log "refresh-rate overlay on"; }
  elif [ $OVL -eq 1 ]; then
    ovl_off; OVL=0; log "refresh-rate overlay off"
  fi

  # ---- floating FPS overlay app
  if [ "$FPS_OVERLAY" = "1" ] && [ "$FPS_MONITOR" = "1" ] && [ $INGAME -eq 1 ]; then
    OK="$OVL_POS/$OVL_SIZE/$OVL_BG/$OVL_X/$OVL_Y"
    if [ "$OK" != "$OV2" ]; then
      pm path "$OVL_PKG" >/dev/null 2>&1 || overlay_install "$MODDIR"
      overlay_start; OV2=$OK; OVLRS=$NOW
    elif ! pidof "$OVL_PKG" >/dev/null 2>&1 && [ $(( NOW - ${OVLRS:-0} )) -ge 5 ]; then
      # some ROMs kill background services when a match loads - bring the counter back
      overlay_start; OVLRS=$NOW; log "overlay app was killed - restarted"
    fi
  elif [ -n "$OV2" ]; then
    overlay_stop; OV2=""; log "fps overlay stopped"
  fi

  # ---- "Test overlay" button: switch the sample off again when its time is up
  if [ -f "$OVLTEST" ]; then
    _t=$(cat "$OVLTEST" 2>/dev/null); case "$_t" in ""|*[!0-9]*) _t=0;; esac
    if [ "$NOW" -ge "$_t" ]; then
      rm -f "$OVLTEST"
      [ $INGAME -eq 1 ] || { overlay_stop; OV2=""; }
    fi
  fi

  # ---- keep the FPS sampler alive (restart if it ever died; not when it quit on purpose)
  if ! kill -0 "$(cat "$DIR/fps.pid" 2>/dev/null)" 2>/dev/null && [ "$(cat "$FPSERR" 2>/dev/null)" != "no-awk" ]; then
    sh "$MODDIR/fps.sh" >/dev/null 2>&1 &
    echo $! > "$DIR/fps.pid"; log "fps sampler was not running - restarted"
  fi

  sleep "$POLL"
done
