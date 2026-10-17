#!/system/bin/sh
# Backend for the WebUI. Used by KernelSU's ksu.exec and by the CGI wrapper.
MODDIR=${0%/*}
. "$MODDIR/common.sh"

json() { printf '{"ok":%s,"msg":"%s"}\n' "$1" "$2"; }
san() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._: x/#()[]-'; }
num() { printf '%s' "$1" | grep -Eo '^[0-9]+(\.[0-9]+)?' | head -n1 || true; }
alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }

size_ok() {
  is_re '^[1-9][0-9]{2,3}x[1-9][0-9]{2,3}$' "$1" || return 1
  [ "${1%x*}" -ge 300 ] && [ "${1%x*}" -le 4096 ] && [ "${1#*x}" -ge 300 ] && [ "${1#*x}" -le 4096 ]
}

# Applies a KEY=VALUE payload (base64) on top of the loaded config. Sets $ERR.
parse_payload() {
  ERR=""
  [ -z "$1" ] && return
  mkdir -p "$DIR"
  F="$DIR/.payload"
  printf '%s' "$1" | base64 -d > "$F" 2>/dev/null || { ERR="bad payload"; rm -f "$F"; return; }
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | tr -d '\r')
    k=${line%%=*}; v=${line#*=}
    case "$k" in
      FILL)            if is_re '^[01]$' "$v"; then FILL=$v; else ERR="bad fill flag"; fi;;
      ENABLED)         if is_re '^[01]$' "$v"; then ENABLED=$v; else ERR="bad enabled flag"; fi;;
      STRETCH_MODE)    if is_re '^(ratio|size|percent)$' "$v"; then STRETCH_MODE=$v; else ERR="bad stretch mode"; fi;;
      STRETCH_RATIO)   if is_re '^[1-9][0-9]?:[1-9][0-9]?$' "$v"; then STRETCH_RATIO=$v; else ERR="bad ratio"; fi;;
      STRETCH_SIZE)    if [ -z "$v" ]; then STRETCH_SIZE=""; elif size_ok "$v"; then STRETCH_SIZE=$v; else ERR="size must be 300-4096 px"; fi;;
      STRETCH_WPCT)    if in_range "$v" 30 100; then STRETCH_WPCT=$v; else ERR="width % must be 30-100"; fi;;
      STRETCH_HPCT)    if in_range "$v" 30 100; then STRETCH_HPCT=$v; else ERR="height % must be 30-100"; fi;;
      RES_SCALE)       if in_range "$v" 40 100; then RES_SCALE=$v; else ERR="resolution scale must be 40-100"; fi;;
      DENSITY_MODE)    if is_re '^(stock|auto|manual)$' "$v"; then DENSITY_MODE=$v; else ERR="bad density mode"; fi;;
      STRETCH_DENSITY) if [ -z "$v" ]; then STRETCH_DENSITY=""; elif is_re '^[1-9][0-9]{2}$' "$v"; then STRETCH_DENSITY=$v; else ERR="bad density"; fi;;
      PACKAGES)        if is_re '^[A-Za-z0-9._ ]+$' "$v"; then PACKAGES=$v; else ERR="bad package list"; fi;;
      CPU_GPU_ENABLED) if is_re '^[01]$' "$v"; then CPU_GPU_ENABLED=$v; else ERR="bad CPU/GPU flag"; fi;;
      CPU_GPU_PROFILE) if is_re '^(balanced|performance)$' "$v"; then CPU_GPU_PROFILE=$v; else ERR="bad CPU/GPU profile"; fi;;
      FPS_LOCK)        if is_re '^[01]$' "$v"; then FPS_LOCK=$v; else ERR="bad fps lock flag"; fi;;
      FPS_CAP)         if in_range "$v" 15 240; then FPS_CAP=$v; else ERR="fps cap must be 15-240"; fi;;
      FPS_METHOD)      if is_re '^(display|both|gamemode)$' "$v"; then FPS_METHOD=$v; else ERR="bad fps method"; fi;;
      FPS_MONITOR)     if is_re '^[01]$' "$v"; then FPS_MONITOR=$v; else ERR="bad monitor flag"; fi;;
      SF_OVERLAY)      if is_re '^[01]$' "$v"; then SF_OVERLAY=$v; else ERR="bad overlay flag"; fi;;
      EXTRA_RR_KEYS)   if is_re '^[A-Za-z0-9_ ]*$' "$v"; then EXTRA_RR_KEYS=$v; else ERR="bad settings key list"; fi;;
      APPLY_DELAY)     if in_range "$v" 0 30; then APPLY_DELAY=$v; else ERR="apply delay must be 0-30"; fi;;
      RESTORE_GRACE)   if in_range "$v" 1 10; then RESTORE_GRACE=$v; else ERR="restore grace must be 1-10"; fi;;
      POLL)            if in_range "$v" 1 10; then POLL=$v; else ERR="poll must be 1-10"; fi;;
      FPS_OVERLAY)     if is_re '^[01]$' "$v"; then FPS_OVERLAY=$v; else ERR="bad overlay flag"; fi;;
      OVL_POS)         if is_re '^(tl|tc|tr|bl|br)$' "$v"; then OVL_POS=$v; else ERR="bad overlay position"; fi;;
      OVL_STYLE)       if is_re '^(compact|full)$' "$v"; then OVL_STYLE=$v; else ERR="bad overlay style"; fi;;
      OVL_SIZE)        if in_range "$v" 8 40; then OVL_SIZE=$v; else ERR="overlay size must be 8-40"; fi;;
      OVL_BG)          if in_range "$v" 0 100; then OVL_BG=$v; else ERR="overlay background must be 0-100"; fi;;
      OVL_X)           if in_range "$v" 0 1000; then OVL_X=$v; else ERR="overlay X must be 0-1000"; fi;;
      OVL_Y)           if in_range "$v" 0 1000; then OVL_Y=$v; else ERR="overlay Y must be 0-1000"; fi;;
    esac
  done < "$F"
  rm -f "$F"
}

# Is the LSPosed hook loaded in THIS boot? -> HS=loaded|stale|error|none, HMSG=text
hook_state() {
  HS=none; HMSG=""
  [ -f "$HOOK_STATUS" ] || return
  HMSG=$(sed -n 's/^msg=//p' "$HOOK_STATUS" 2>/dev/null | head -n1)
  _hb=$(sed -n 's/^boot_id=//p' "$HOOK_STATUS" 2>/dev/null | head -n1)
  _cb=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  _fresh=0
  if [ -n "$_hb" ] && [ -n "$_cb" ]; then
    [ "$_hb" = "$_cb" ] && _fresh=1
  else
    _he=$(sed -n 's/^epoch=//p' "$HOOK_STATUS" 2>/dev/null | head -n1)
    _up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)
    if is_re '^[0-9]+$' "$_he" && is_re '^[0-9]+$' "$_up" && [ "$_he" -ge $(( $(date +%s) - _up - 300 )) ]; then _fresh=1; fi
  fi
  if [ $_fresh -eq 0 ]; then HS=stale
  elif grep -q '^hooked=1' "$HOOK_STATUS" 2>/dev/null; then HS=loaded
  else HS=error; fi
}

cmd_state() {
  load_cfg
  PHYS=$(cat "$DIR/phys" 2>/dev/null); [ -z "$PHYS" ] && PHYS=$(phys_size)
  DENS=$(cat "$DIR/phys_dens" 2>/dev/null)
  T=$(calc_size)
  TD=$(calc_density)
  MODE=$(sed -n 's/^mode=//p' "$STATUS" 2>/dev/null | head -n1)
  APP=$(sed -n 's/^applied=//p' "$STATUS" 2>/dev/null | head -n1)
  [ -z "$MODE" ] && MODE=idle
  CUR=${APP:-$PHYS}
  VER=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1)
  SVC=0; alive "$DIR/service.pid" && SVC=1
  WEB=0; alive "$DIR/web.pid" && WEB=1
  SMP=0; alive "$DIR/fps.pid" && SMP=1
  hook_state
  [ -s "$RATES" ] || save_rates
  RJ=$(tr -s ' ' ',' < "$RATES" 2>/dev/null | sed 's/^,//; s/,$//')
  LHZ=$(pick_refresh "$FPS_CAP"); LEX=0; [ "$LHZ" = "$FPS_CAP" ] && LEX=1
  GMF=$(gm_fps "$FPS_CAP")
  LA=0; [ -f "$FPSACT" ] && LA=1
  MODEL=$(getprop ro.product.model)
  AND=$(getprop ro.build.version.release)
  printf '{"version":"%s","enabled":%s,"smode":"%s","ratio":"%s","size":"%s","wpct":%s,"hpct":%s,"scale":%s,"dmode":"%s","density":"%s","targetDensity":"%s",' \
    "$(san "$VER")" "$ENABLED" "$STRETCH_MODE" "$STRETCH_RATIO" "$STRETCH_SIZE" "$STRETCH_WPCT" "$STRETCH_HPCT" "$RES_SCALE" "$DENSITY_MODE" "$STRETCH_DENSITY" "$(san "$TD")"
  printf '"packages":"%s","phys":"%s","physDens":"%s","target":"%s","cur":"%s","mode":"%s","service":%s,"web":%s,"sampler":%s,"port":%s,"fill":%s,"hook":"%s","hookMsg":"%s",' \
    "$(san "$PACKAGES")" "$(san "$PHYS")" "$(san "$DENS")" "$(san "$T")" "$(san "$CUR")" "$(san "$MODE")" "$SVC" "$WEB" "$SMP" "$WEBUI_PORT" "$FILL" "$HS" "$(san "$HMSG")"
  CGSTAT=$(cat "$DIR/cpugpu_status" 2>/dev/null | tr '\n' ';' | tr -cd 'A-Za-z0-9._=:-;')
  printf '"cpuGpuEnabled":%s,"cpuGpuProfile":"%s","cpuGpuStatus":"%s",' "$CPU_GPU_ENABLED" "$CPU_GPU_PROFILE" "$(san "$CGSTAT")"
  printf '"fpsLock":%s,"fpsCap":%s,"fpsMethod":"%s","fpsMonitor":%s,"sfOverlay":%s,"extraKeys":"%s","applyDelay":%s,"grace":%s,"poll":%s,' \
    "$FPS_LOCK" "$FPS_CAP" "$FPS_METHOD" "$FPS_MONITOR" "$SF_OVERLAY" "$(san "$EXTRA_RR_KEYS")" "$APPLY_DELAY" "$RESTORE_GRACE" "$POLL"
  # pm / appops are slow (each starts a Java process on the phone): ask once every 20 s, not every poll
  OA=0; OP=0; _fc="$DIR/.ovlflags"; _fn=$(date +%s); _ft=$(sed -n 1p "$_fc" 2>/dev/null)
  if is_re '^[0-9]+$' "$_ft" && [ $(( _fn - _ft )) -ge 0 ] && [ $(( _fn - _ft )) -lt 20 ]; then
    OA=$(sed -n 2p "$_fc" 2>/dev/null); OP=$(sed -n 3p "$_fc" 2>/dev/null)
    is_re '^[01]$' "$OA" || OA=0; is_re '^[01]$' "$OP" || OP=0
  else
    pm path "$OVL_PKG" >/dev/null 2>&1 && OA=1
    appops get "$OVL_PKG" SYSTEM_ALERT_WINDOW 2>/dev/null | grep -qi allow && OP=1
    printf '%s\n%s\n%s\n' "$_fn" "$OA" "$OP" > "$_fc" 2>/dev/null
  fi
  OR=0; pidof "$OVL_PKG" >/dev/null 2>&1 && OR=1
  printf '"fpsOverlay":%s,"ovlPos":"%s","ovlStyle":"%s","ovlSize":%s,"ovlBg":%s,"ovlX":%s,"ovlY":%s,"ovlApp":%s,"ovlPerm":%s,"ovlRunning":%s,"fpsErr":"%s","ovlInstallMsg":"%s","ovlStartMsg":"%s",' \
    "$FPS_OVERLAY" "$OVL_POS" "$OVL_STYLE" "$OVL_SIZE" "$OVL_BG" "$OVL_X" "$OVL_Y" "$OA" "$OP" "$OR" "$(san "$(cat "$FPSERR" 2>/dev/null)")" \
    "$(san "$(head -c 220 "$OVL_INSTALL_LOG" 2>/dev/null | tr -d '"\\')")" "$(san "$(head -c 160 "$DIR/ovl_start.txt" 2>/dev/null | tr -d '"\\')")"
  printf '"rates":[%s],"lockHz":%s,"lockExact":%s,"gmFps":%s,"lockActive":%s,"model":"%s","android":"%s"}\n' \
    "$RJ" "${LHZ:-0}" "$LEX" "$GMF" "$LA" "$(san "$MODEL")" "$(san "$AND")"
}

cmd_live() {
  _fps=$(num "$(kv_get fps "$LIVE")"); _ft=$(num "$(kv_get ft "$LIVE")"); _wo=$(num "$(kv_get worst "$LIVE")")
  _hz=$(num "$(kv_get hz "$LIVE")"); _jk=$(num "$(kv_get jank "$LIVE")"); _ts=$(num "$(kv_get ts "$LIVE")")
  _ly=$(kv_get layer "$LIVE"); _mt=$(kv_get method "$LIVE")
  AGE=-1; [ -n "$_ts" ] && AGE=$(( $(date +%s) - _ts ))
  _hzn=$(num "$(kv_get hzn "$LIVE")")   # sampled once a second by fps.sh (no dumpsys per request)
  _fm=$(num "$(kv_get frame "$LIVE")")
  _h=$(tail -n 60 "$HIST" 2>/dev/null | grep -E '^[0-9.]+$' | tr '\n' ',' | sed 's/,$//')
  _lsx=""
  if [ -f "$LASTSESS" ]; then
    _lsx=$(printf '{"secs":%s,"avg":%s,"min":%s,"max":%s,"p1":%s,"cap":%s}' \
      "$(num "$(kv_get secs "$LASTSESS")")" "$(num "$(kv_get avg "$LASTSESS")")" "$(num "$(kv_get min "$LASTSESS")")" \
      "$(num "$(kv_get max "$LASTSESS")")" "$(num "$(kv_get p1 "$LASTSESS")")" "$(num "$(kv_get cap "$LASTSESS")")")
  fi
  INg=0; [ -f "$INGF" ] && INg=1
  _cn=$(num "$(cat "$CAPNOTE" 2>/dev/null)"); _cn=${_cn:-0}
  _ag=$(num "$(kv_get fage "$LIVE")"); _ag=${_ag:-0}   # ms since the newest present (fps.sh)
  printf '{"ts":%s,"frameMs":%s,"inGame":%s,"fps":%s,"ft":%s,"worst":%s,"hz":%s,"jank":%s,"layer":"%s","method":"%s","age":%s,"hzNow":%s,"hist":[%s],"last":%s,"err":"%s","capNote":%s,"frameAge":%s}\n' \
    "${_ts:-0}" "${_fm:-0}" "$INg" "${_fps:-0}" "${_ft:-0}" "${_wo:-0}" "${_hz:-0}" "${_jk:-0}" "$(san "$_ly")" "$(san "$_mt")" "$AGE" "${_hzn:-0}" "$_h" "${_lsx:-null}" "$(san "$(cat "$FPSERR" 2>/dev/null)")" "$_cn" "${_ag:-0}"
}

cmd_save() {
  load_cfg; parse_payload "$1"
  [ -n "$ERR" ] && { json 0 "$ERR"; return; }
  write_cfg
  sync_fill
  json 1 "Saved"
}

cmd_test() {
  load_cfg; parse_payload "$1"
  [ -n "$ERR" ] && { json 0 "$ERR"; return; }
  alive "$DIR/service.pid" || { json 0 "Service not running - reboot after installing"; return; }
  PHYS=$(cat "$DIR/phys" 2>/dev/null); [ -z "$PHYS" ] && PHYS=$(phys_size)
  T=$(calc_size)
  [ -z "$T" ] && { json 0 "Could not read screen size"; return; }
  echo "$T" > "$DIR/test_size"
  apply_cfg "$T"
  echo $(( $(date +%s) + 10 )) > "$TESTF"
  json 1 "Testing $T for 10s"
}

cmd_locktest() {
  json 0 "FPS cap feature has been removed; use CPU/GPU profile instead"; return
  load_cfg; parse_payload "$1"
  [ -n "$ERR" ] && { json 0 "$ERR"; return; }
  alive "$DIR/service.pid" || { json 0 "Service not running - reboot after installing"; return; }
  [ -f "$LOCKTESTF" ] && { json 0 "A lock test is already running"; return; }
  FPS_METHOD=display
  fps_apply "$FPS_CAP" display-only
  echo $(( $(date +%s) + 12 )) > "$LOCKTESTF"
  json 1 "Panel locked to $(pick_refresh "$FPS_CAP") Hz for 12s - watch Live panel Hz"
}

cmd_restore() {
  rm -f "$TESTF" "$DIR/test_size"
  [ -f "$ACTIVE" ] && do_restore
  touch "$RESETF"
  json 1 "Restored"
}

cmd_diag_body() {
  load_cfg
  echo "== device"
  echo "model: $(getprop ro.product.brand) $(getprop ro.product.model)"
  echo "manufacturer: $(getprop ro.product.manufacturer) | soc vendor: $(getprop ro.soc.manufacturer) | soc model: $(getprop ro.soc.model)"
  echo "board platform: $(getprop ro.board.platform) | hardware: $(getprop ro.hardware) | vendor fingerprint: $(getprop ro.vendor.build.fingerprint)"
  echo "rom: $(getprop ro.build.display.id)"
  echo "android: $(getprop ro.build.version.release) (sdk $(getprop ro.build.version.sdk))"
  echo "soc: $(getprop ro.board.platform) $(getprop ro.hardware)"
  echo "== display"
  wm size 2>/dev/null; wm density 2>/dev/null
  echo "panel rates: $(cat "$RATES" 2>/dev/null)"
  echo "active Hz now (SurfaceFlinger): $(current_hz)"
  echo "== refresh/fps keys in settings (system)"
  settings list system 2>/dev/null | grep -i -E 'refresh|fps|frame' || echo "(none)"
  echo "== refresh/fps keys in settings (secure/global)"
  { settings list secure; settings list global; } 2>/dev/null | grep -i -E 'refresh_rate|fps' || echo "(none)"
  echo "== lock plan: cap=$FPS_CAP method=$FPS_METHOD -> panel $(pick_refresh "$FPS_CAP") Hz, game-mode fps $(gm_fps "$FPS_CAP")"
  echo "lock active: $([ -f "$FPSACT" ] && echo yes || echo no)"
  echo "lock method that will be used for cap $FPS_CAP: $(eff_method "$FPS_CAP") (chosen: $FPS_METHOD)"
  echo "cap not held (measured fps while locked, empty = fine): $(cat "$CAPNOTE" 2>/dev/null)"
  echo "== game mode"
  for p in $PACKAGES; do pm path "$p" >/dev/null 2>&1 && { echo "$p:"; cmd game list-modes "$p" 2>&1 | head -n 4; }; done
  echo "== SurfaceFlinger layers for the game"
  for p in $PACKAGES; do dumpsys SurfaceFlinger --list 2>/dev/null | grep -F "$p" | head -n 8; done
  echo "== overlay app"
  echo "install log: $(cat "$OVL_INSTALL_LOG" 2>/dev/null)"
  echo "start log: $(cat "$DIR/ovl_start.txt" 2>/dev/null)"
  echo "installed: $(pm path "$OVL_PKG" 2>&1 | head -n1)"
  echo "overlay permission: $(appops get "$OVL_PKG" SYSTEM_ALERT_WINDOW 2>&1 | head -n1)"
  echo "running: $(pidof "$OVL_PKG" || echo no)"
  echo "overlay window: $(dumpsys window windows 2>/dev/null | grep -c "$OVL_PKG") match(es) in window list"
  echo "data file: $(ls -l "$OVL_FILE" 2>&1 | head -n1)"; cat "$OVL_FILE" 2>/dev/null; echo
  echo "selinux: $(getenforce 2>&1)  data file label: $(ls -Z "$OVL_FILE" 2>&1 | head -n1)"
  echo "-- overlay app errors in logcat (crashes, permission or window problems)"
  logcat -d -t 3000 2>/dev/null | grep -E "com\.codm\.fps|OverlayService" | grep -v -E "ActivityManager: (Start proc|Killing)" | tail -n 12
  echo "== fps sampler"
  echo "error code: $(cat "$FPSERR" 2>/dev/null)"
  echo "-- latency probe per layer (lines returned / first line)"
  dumpsys SurfaceFlinger --list 2>/dev/null | tr -d '\r' | grep -v -E '^(Background for|Bounds for|Task=)' | head -n 25 | while IFS= read -r l; do
    _o=$(dumpsys SurfaceFlinger --latency "$l" 2>&1); echo "$(printf '%s\n' "$_o" | wc -l) lines | $(printf '%s\n' "$_o" | sed -n 2p | tr '\t' ' ') | $l"
  done
  echo "-- captured while in game (only written when no frame source worked)"
  cat "$DIR/fps_debug.txt" 2>/dev/null || echo "(none - the sampler found frames, or the game has not been on screen yet)"
  echo "-- TimeStats probe (per-layer frame counters; used when --latency is empty)"
  dumpsys SurfaceFlinger --timestats -enable >/dev/null 2>&1
  _ts=$(dumpsys SurfaceFlinger --timestats -dump -maxlayers 100 2>&1 | tr -d '\r')
  echo "lines: $(printf '%s\n' "$_ts" | wc -l) | head: $(printf '%s\n' "$_ts" | head -n 2 | tr '\n' '|')"
  printf '%s\n' "$_ts" | grep -E '^[[:space:]]*(layerName|totalFrames) *=' | head -n 24
  echo "sampler method in use: $(cat "$DIR/fps_method" 2>/dev/null || echo none)"
  echo "-- MediaTek FPSGO (if present)"
  ls /sys/kernel/fpsgo /proc/fpsgo 2>/dev/null | head -n 5
  [ -d /sys/kernel/debug ] && [ ! -e /sys/kernel/debug/fpsgo ] && mount -t debugfs none /sys/kernel/debug 2>/dev/null
  head -n 12 /sys/kernel/debug/fpsgo/common/fpsgo_status 2>/dev/null
  echo "busybox+awk: $(find_bb || echo MISSING)"
  echo "running: $(alive "$DIR/fps.pid" && echo yes || echo no)"
  echo "live: $(cat "$LIVE" 2>/dev/null | tr '\n' ' ')"
  echo "last session: $(cat "$LASTSESS" 2>/dev/null | tr '\n' ' ')"
  echo "== log (tail)"
  tail -n 25 "$LOG" 2>/dev/null
}

# Diagnostics: show it and also keep a copy you can attach (Downloads/CODM_diag.txt)
cmd_diag() {
  mkdir -p "$DIR"
  cmd_diag_body > "$DIR/diag.txt" 2>&1
  cp "$DIR/diag.txt" /sdcard/Download/CODM_diag.txt 2>/dev/null && chmod 666 /sdcard/Download/CODM_diag.txt 2>/dev/null
  cat "$DIR/diag.txt"
  [ -f /sdcard/Download/CODM_diag.txt ] && echo "(a copy was saved to Downloads/CODM_diag.txt)"
}

# "Test overlay": show a sample counter for 10 s, no game needed. Tells overlay problems apart from FPS-data problems.
cmd_ovltest() {
  load_cfg; parse_payload "$1"
  [ -n "$ERR" ] && { json 0 "$ERR"; return; }
  pm path "$OVL_PKG" >/dev/null 2>&1 || overlay_install "$MODDIR"
  pm path "$OVL_PKG" >/dev/null 2>&1 || { json 0 "Overlay app is not installed - see the red message above"; return; }
  appops set "$OVL_PKG" SYSTEM_ALERT_WINDOW allow >/dev/null 2>&1
  mkdir -p "$OVL_DIR" 2>/dev/null; chmod 755 "$OVL_DIR" 2>/dev/null
  overlay_start
  _o=$(cat "$DIR/ovl_start.txt" 2>/dev/null)
  case "$_o" in *[Ee]rror*|*"not allowed"*|*denied*|*"not found"*) json 0 "Android refused to start the overlay: $(san "$_o" | head -c 120)"; return;; esac
  echo $(( $(date +%s) + 10 )) > "$OVLTEST"
  printf '<font color="#39d98a"><b>120</b></font> FPS &middot; 8.3 ms<br>overlay test' > "$OVL_FILE.t" && mv "$OVL_FILE.t" "$OVL_FILE"
  chmod 644 "$OVL_FILE" 2>/dev/null
  json 1 "Overlay test: look at your chosen corner for 10 s"
}

case "$1" in
  state)    cmd_state;;
  live)     cmd_live;;
  log)      { tail -n 40 "$LOG" 2>/dev/null || echo "(no log yet)"
              echo "--- LSPosed hook status ---"
              cat "$HOOK_STATUS" 2>/dev/null || echo "(no status file - hook never loaded)"; };;
  diag)     cmd_diag;;
  save)     cmd_save "$2";;
  test)     cmd_test "$2";;
  locktest) cmd_locktest "$2";;
  restore)  cmd_restore;;
  ovltest)  cmd_ovltest "$2";;
  *)        json 0 "unknown command";;
esac
