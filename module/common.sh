#!/system/bin/sh
# Shared helpers for CODM Ultra Stretch. Sourced only; no side effects.
DIR="${CODM_DIR:-/data/adb/codm_stretch}"
CFG="$DIR/config.conf"
LOG="$DIR/log.txt"
ACTIVE="$DIR/.active"          # stretch currently applied
FPSACT="$DIR/.fps_active"      # fps lock currently applied
OVLACT="$DIR/.ovl_active"      # system refresh-rate overlay switched on by us
STATUS="$DIR/status"
TESTF="$DIR/test_until"
LOCKTESTF="$DIR/locktest_until"
RESETF="$DIR/reset_req"
INGF="$DIR/ingame"             # exists while CODM is on screen (the FPS sampler watches this)
LIVE="$DIR/live"               # latest real FPS sample
HIST="$DIR/fps_hist"           # last ~120 one-second samples
SESS="$DIR/.sess"              # samples of the current game session
LASTSESS="$DIR/last_session"
RATES="$DIR/rates"             # panel refresh rates, e.g. "60 90 120 "
OVL_PKG="com.codm.fps"
OVL_DIR="${CODM_OVL_DIR:-/data/data/$OVL_PKG/files}"
OVL_FILE="$OVL_DIR/live.html"  # the overlay app polls this file
OVLTEST="$DIR/ovl_test_until"   # "Test overlay" button: sample counter stays up until this time
FPSERR="$DIR/fps_err"          # why the sampler has no data (shown in the WebUI)
CAPNOTE="$DIR/cap_note"        # FPS measured above the cap while the lock is on (cap not held)
HOOK_STATUS="${CODM_HOOK_STATUS:-/data/system/codm_stretch_hook.txt}"   # written by the LSPosed hook
HOOK_OFF="${CODM_HOOK_OFF:-/data/system/codm_stretch_off}"            # kill switch read by the hook
PATH="$PATH:/system/bin:/system/xbin:/vendor/bin"
export PATH
DEF_PACKAGES="com.activision.callofduty.shooter com.garena.game.codm com.tencent.tmgp.cod"

is_re() { printf '%s\n' "$2" | grep -Eq "$1"; }
# in_range VALUE LOW HIGH  (integers)
in_range() { is_re '^[0-9]{1,4}$' "$1" && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }

log() {
  mkdir -p "$DIR"
  echo "$(date '+%m-%d %H:%M:%S') $1" >> "$LOG"
  if [ $(wc -c < "$LOG" 2>/dev/null || echo 0) -gt 40000 ]; then
    tail -n 100 "$LOG" > "$LOG.t" && mv "$LOG.t" "$LOG"
  fi
}

cfg_get() { sed -n "s/^$1=\"\(.*\)\"[[:space:]]*\$/\1/p" "$CFG" 2>/dev/null | head -n1; }
kv_get()  { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n1; }

# A busybox that has awk (the FPS sampler needs it)
find_bb() {
  for b in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox "$(command -v busybox 2>/dev/null)"; do
    [ -n "$b" ] && [ -x "$b" ] && "$b" awk 'BEGIN{exit 0}' 2>/dev/null && { echo "$b"; return 0; }
  done
  return 1
}

# Read + validate config (invalid/missing values fall back to defaults)
load_cfg() {
  ENABLED=$(cfg_get ENABLED);              is_re '^[01]$' "$ENABLED" || ENABLED=1
  STRETCH_RATIO=$(cfg_get STRETCH_RATIO);  is_re '^[1-9][0-9]?:[1-9][0-9]?$' "$STRETCH_RATIO" || STRETCH_RATIO="4:3"
  STRETCH_SIZE=$(cfg_get STRETCH_SIZE);    is_re '^[1-9][0-9]{2,3}x[1-9][0-9]{2,3}$' "$STRETCH_SIZE" || STRETCH_SIZE=""
  STRETCH_MODE=$(cfg_get STRETCH_MODE)
  is_re '^(ratio|size|percent)$' "$STRETCH_MODE" || { if [ -n "$STRETCH_SIZE" ]; then STRETCH_MODE=size; else STRETCH_MODE=ratio; fi; }
  STRETCH_WPCT=$(cfg_get STRETCH_WPCT);    in_range "$STRETCH_WPCT" 30 100 || STRETCH_WPCT=100
  STRETCH_HPCT=$(cfg_get STRETCH_HPCT);    in_range "$STRETCH_HPCT" 30 100 || STRETCH_HPCT=60
  RES_SCALE=$(cfg_get RES_SCALE);          in_range "$RES_SCALE" 40 100 || RES_SCALE=100
  STRETCH_DENSITY=$(cfg_get STRETCH_DENSITY); is_re '^[1-9][0-9]{2}$' "$STRETCH_DENSITY" || STRETCH_DENSITY=""
  DENSITY_MODE=$(cfg_get DENSITY_MODE)
  is_re '^(stock|auto|manual)$' "$DENSITY_MODE" || { if [ -n "$STRETCH_DENSITY" ]; then DENSITY_MODE=manual; else DENSITY_MODE=stock; fi; }
  PACKAGES=$(cfg_get PACKAGES);            is_re '^[A-Za-z0-9._ ]+$' "$PACKAGES" || PACKAGES="$DEF_PACKAGES"
  FILL=$(cfg_get FILL);                    is_re '^[01]$' "$FILL" || FILL=1
  WEBSERVER=$(cfg_get WEBSERVER);          is_re '^[01]$' "$WEBSERVER" || WEBSERVER=1
  WEBUI_PORT=$(cfg_get WEBUI_PORT);        is_re '^[1-9][0-9]{3,4}$' "$WEBUI_PORT" || WEBUI_PORT=8088
  CPU_GPU_ENABLED=$(cfg_get CPU_GPU_ENABLED); is_re '^[01]$' "$CPU_GPU_ENABLED" || CPU_GPU_ENABLED=0
  CPU_GPU_PROFILE=$(cfg_get CPU_GPU_PROFILE); is_re '^(balanced|performance)$' "$CPU_GPU_PROFILE" || CPU_GPU_PROFILE=balanced
  FPS_LOCK=$(cfg_get FPS_LOCK);            is_re '^[01]$' "$FPS_LOCK" || FPS_LOCK=0
  FPS_CAP=$(cfg_get FPS_CAP);              in_range "$FPS_CAP" 15 240 || FPS_CAP=60
  FPS_METHOD=$(cfg_get FPS_METHOD);        is_re '^(display|both|gamemode)$' "$FPS_METHOD" || FPS_METHOD=display
  FPS_MONITOR=$(cfg_get FPS_MONITOR);      is_re '^[01]$' "$FPS_MONITOR" || FPS_MONITOR=1
  SF_OVERLAY=$(cfg_get SF_OVERLAY);        is_re '^[01]$' "$SF_OVERLAY" || SF_OVERLAY=0
  EXTRA_RR_KEYS=$(cfg_get EXTRA_RR_KEYS);  is_re '^[A-Za-z0-9_ ]*$' "$EXTRA_RR_KEYS" || EXTRA_RR_KEYS=""
  APPLY_DELAY=$(cfg_get APPLY_DELAY);      in_range "$APPLY_DELAY" 0 30 || APPLY_DELAY=0
  RESTORE_GRACE=$(cfg_get RESTORE_GRACE);  in_range "$RESTORE_GRACE" 1 10 || RESTORE_GRACE=2
  POLL=$(cfg_get POLL);                    in_range "$POLL" 1 10 || POLL=3
  FPS_OVERLAY=$(cfg_get FPS_OVERLAY);      is_re '^[01]$' "$FPS_OVERLAY" || FPS_OVERLAY=1
  OVL_POS=$(cfg_get OVL_POS);              is_re '^(tl|tc|tr|bl|br)$' "$OVL_POS" || OVL_POS=tl
  OVL_STYLE=$(cfg_get OVL_STYLE);          is_re '^(compact|full)$' "$OVL_STYLE" || OVL_STYLE=full
  OVL_SIZE=$(cfg_get OVL_SIZE);            in_range "$OVL_SIZE" 8 40 || OVL_SIZE=14
  OVL_BG=$(cfg_get OVL_BG);                in_range "$OVL_BG" 0 100 || OVL_BG=45
  OVL_X=$(cfg_get OVL_X);                  in_range "$OVL_X" 0 1000 || OVL_X=24
  OVL_Y=$(cfg_get OVL_Y);                  in_range "$OVL_Y" 0 1000 || OVL_Y=24
}

write_cfg() {
  mkdir -p "$DIR"
  cat > "$CFG.tmp" <<CFGEOF
# CODM Ultra Stretch config. The WebUI edits this file; hand edits are fine.
# ENABLED          1 = auto-stretch on, 0 = off
# STRETCH_MODE     ratio | size | percent
# STRETCH_RATIO    landscape ratio, e.g. 4:3 (strong), 16:10, 16:9 (light)
# STRETCH_SIZE     exact size in natural/portrait orientation, e.g. 1080x1440
# STRETCH_WPCT/HPCT  percent mode: width / height as % of the panel (30-100)
# RES_SCALE        render resolution scale in % (40-100), applied on top of any mode
# DENSITY_MODE     stock | auto (follows RES_SCALE) | manual (STRETCH_DENSITY)
# STRETCH_DENSITY  manual density while in game
# PACKAGES         games to watch (space separated)
# FILL             1 = ask the LSPosed hook to stretch to fill the panel (no black bars)
# CPU_GPU_ENABLED  1 = apply CPU/GPU frequency ceiling while CODM is foreground
# CPU_GPU_PROFILE  balanced (85% ceiling) | performance (100% ceiling)
# FPS_LOCK         legacy, disabled by this build
# FPS_CAP          target FPS (15-240)
# FPS_METHOD       display (lock panel refresh rate) | both (+ Game Mode limiter) | gamemode
# FPS_MONITOR      1 = measure real FPS from SurfaceFlinger while in game
# SF_OVERLAY       1 = show Android's own refresh-rate overlay while in game (Hz only)
# FPS_OVERLAY      1 = floating real-FPS counter drawn over the game (overlay app)
# OVL_POS          tl | tc | tr | bl | br (corner of the screen)
# OVL_STYLE        compact (one line) | full (FPS, frame time, stutters)
# OVL_SIZE         text size 8-40
# OVL_BG           background darkness 0-100 %
# OVL_X / OVL_Y    distance from the screen edge in px
# EXTRA_RR_KEYS    extra 'settings system' keys to lock to the target refresh rate
# APPLY_DELAY      seconds to wait after the game appears before applying
# RESTORE_GRACE    number of polls the game may be missing before restoring
# POLL             seconds between checks
# WEBSERVER        1 = start localhost web server for the WebUI (needed for Magisk)
# WEBUI_PORT       port for that server
ENABLED="$ENABLED"
STRETCH_MODE="$STRETCH_MODE"
STRETCH_RATIO="$STRETCH_RATIO"
STRETCH_SIZE="$STRETCH_SIZE"
STRETCH_WPCT="$STRETCH_WPCT"
STRETCH_HPCT="$STRETCH_HPCT"
RES_SCALE="$RES_SCALE"
DENSITY_MODE="$DENSITY_MODE"
STRETCH_DENSITY="$STRETCH_DENSITY"
PACKAGES="$PACKAGES"
FILL="$FILL"
CPU_GPU_ENABLED="$CPU_GPU_ENABLED"
CPU_GPU_PROFILE="$CPU_GPU_PROFILE"
FPS_LOCK="0"
FPS_CAP="$FPS_CAP"
FPS_METHOD="$FPS_METHOD"
FPS_MONITOR="$FPS_MONITOR"
SF_OVERLAY="$SF_OVERLAY"
EXTRA_RR_KEYS="$EXTRA_RR_KEYS"
APPLY_DELAY="$APPLY_DELAY"
RESTORE_GRACE="$RESTORE_GRACE"
POLL="$POLL"
FPS_OVERLAY="$FPS_OVERLAY"
OVL_POS="$OVL_POS"
OVL_STYLE="$OVL_STYLE"
OVL_SIZE="$OVL_SIZE"
OVL_BG="$OVL_BG"
OVL_X="$OVL_X"
OVL_Y="$OVL_Y"
WEBSERVER="$WEBSERVER"
WEBUI_PORT="$WEBUI_PORT"
CFGEOF
  mv "$CFG.tmp" "$CFG"
}

phys_size() { wm size 2>/dev/null | tr -d '\r' | grep -i physical | head -n1 | sed 's/.*: *//'; }
phys_dens() { wm density 2>/dev/null | tr -d '\r' | grep -i physical | head -n1 | sed 's/.*: *//'; }

# ------------------------------------------------------------------ stretch
# Needs $PHYS and the loaded config. Prints WxH (natural orientation).
calc_size() {
  _w=""; _h=""
  if is_re '^[0-9]+x[0-9]+$' "$PHYS"; then _w=${PHYS%x*}; _h=${PHYS#*x}; fi
  case "$STRETCH_MODE" in
    size)
      [ -n "$STRETCH_SIZE" ] || return
      _nw=${STRETCH_SIZE%x*}; _nh=${STRETCH_SIZE#*x};;
    percent)
      [ -n "$_w" ] || return
      _nw=$(( _w * STRETCH_WPCT / 100 )); _nh=$(( _h * STRETCH_HPCT / 100 ));;
    *)
      [ -n "$_w" ] || return
      _a=${STRETCH_RATIO%:*}; _b=${STRETCH_RATIO#*:}
      if [ "$_a" -lt "$_b" ]; then _t=$_a; _a=$_b; _b=$_t; fi
      if [ "$_w" -le "$_h" ]; then
        _nw=$_w; _nh=$(( _w * _a / _b )); [ "$_nh" -gt "$_h" ] && _nh=$_h
      else
        _nh=$_h; _nw=$(( _h * _a / _b )); [ "$_nw" -gt "$_w" ] && _nw=$_w
      fi;;
  esac
  _nw=$(( _nw * RES_SCALE / 100 )); _nh=$(( _nh * RES_SCALE / 100 ))
  _nw=$(( _nw / 2 * 2 )); _nh=$(( _nh / 2 * 2 ))
  [ "$_nw" -lt 300 ] && _nw=300
  [ "$_nh" -lt 300 ] && _nh=300
  echo "${_nw}x${_nh}"
}

# Density to use while in game ("" = leave unchanged)
calc_density() {
  case "$DENSITY_MODE" in
    manual) echo "$STRETCH_DENSITY";;
    auto)
      _pd=$(cat "$DIR/phys_dens" 2>/dev/null); [ -z "$_pd" ] && _pd=$(phys_dens)
      is_re '^[0-9]+$' "$_pd" || return
      # lower render resolution -> proportionally lower density keeps the HUD the same size
      [ "$RES_SCALE" -lt 100 ] && echo $(( _pd * RES_SCALE / 100 ));;
    *) echo "";;
  esac
}

# Remember the user's own overrides so we can put them back later
snapshot() {
  [ -f "$ACTIVE" ] && return
  wm size 2>/dev/null | tr -d '\r' | sed -n 's/^Override size: *//p' | head -n1 > "$DIR/orig_size"
  wm density 2>/dev/null | tr -d '\r' | sed -n 's/^Override density: *//p' | head -n1 > "$DIR/orig_dens"
}

restore_density() {
  _od=$(cat "$DIR/orig_dens" 2>/dev/null)
  if [ -n "$_od" ]; then wm density "$_od"; else wm density reset; fi
}

# do_apply SIZE [DENSITY]
do_apply() {
  snapshot
  wm size "$1"
  if [ -n "$2" ]; then wm density "$2"; elif [ -f "$ACTIVE" ]; then restore_density; fi
  touch "$ACTIVE"
}
apply_cfg() { do_apply "$1" "$(calc_density)"; }

do_restore() {
  _os=$(cat "$DIR/orig_size" 2>/dev/null)
  if [ -n "$_os" ]; then wm size "$_os"; else wm size reset; fi
  restore_density
  rm -f "$ACTIVE"
}

# Tell the LSPosed hook (inside system_server) whether it may stretch
sync_fill() {
  if [ "$FILL" = "1" ]; then
    [ -f "$HOOK_OFF" ] && rm -f "$HOOK_OFF"
  else
    [ -f "$HOOK_OFF" ] || : > "$HOOK_OFF"
  fi
}

set_status() { printf 'mode=%s\napplied=%s\n' "$1" "$2" > "$STATUS"; }

# --------------------------------------------------------------- refresh rate
# Supported panel refresh rates, rounded, ascending, space separated
supported_rates() {
  dumpsys display 2>/dev/null | grep -o -E '(fps|refreshRate)=[0-9]+(\.[0-9]*)?' | sed 's/.*=//' | while read -r x; do
    i=${x%%.*}; f=${x#*.}; [ "$f" = "$x" ] && f=0
    d=${f%"${f#?}"}; [ -z "$d" ] && d=0
    [ "$d" -ge 5 ] && i=$((i + 1))
    [ "$i" -ge 20 ] && [ "$i" -le 240 ] && echo "$i"
  done | sort -un | tr '\n' ' '
}
save_rates() { mkdir -p "$DIR"; _r=$(supported_rates); [ -n "$_r" ] && printf '%s' "$_r" > "$RATES"; }

# Active panel refresh rate from SurfaceFlinger's vsync period (first line of --latency)
current_hz() {
  _p=$(dumpsys SurfaceFlinger --latency __codm_none__ 2>/dev/null | head -n1 | tr -d '\r ')
  is_re '^[0-9]{6,9}$' "$_p" || { echo 0; return; }
  echo $(( (2000000000 + _p) / (2 * _p) ))
}

# eff_method CAP -> the method that can really hold CAP.
# A display lock can only cap at a rate the panel supports (60/90/120...). For any other
# cap (e.g. 90 on a 60/120 panel, 72) it cannot cap at all, so Game Mode is added.
eff_method() {
  _m=$FPS_METHOD
  if [ "$_m" = display ] && [ -s "$RATES" ]; then
    _ex=0
    for r in $(cat "$RATES"); do [ "$r" -eq "$1" ] && _ex=1; done
    [ $_ex -eq 0 ] && _m=both
  fi
  echo "$_m"
}

# pick_refresh CAP -> panel mode to lock.
#  display lock: the exact panel rate equal to CAP (60 on a 120 Hz panel -> locks 60, a real cap)
#  with Game Mode: a multiple of CAP (60 on 120 Hz -> 120, so each game frame is shown exactly twice)
pick_refresh() {
  _cap=$1; _rs=$(cat "$RATES" 2>/dev/null)
  [ -z "$_rs" ] && { echo "$_cap"; return; }
  if [ "$(eff_method "$_cap")" = display ]; then
    for r in $_rs; do [ "$r" -eq "$_cap" ] && { echo "$r"; return; }; done
  fi
  for r in $_rs; do [ "$r" -ge "$_cap" ] && [ $((r % _cap)) -eq 0 ] && { echo "$r"; return; }; done
  for r in $_rs; do [ "$r" -ge "$_cap" ] && { echo "$r"; return; }; done
  _m=""; for r in $_rs; do _m=$r; done; echo "$_m"
}

# Game Mode only accepts a few fps values: largest allowed value <= CAP (min 30)
gm_fps() { _c=$1; _o=30; for a in 30 45 60 90 120; do [ "$a" -le "$_c" ] && _o=$a; done; echo "$_o"; }

rr_keys() { echo "peak_refresh_rate min_refresh_rate user_refresh_rate $EXTRA_RR_KEYS"; }

fps_snapshot() {
  [ -f "$FPSACT" ] && return
  : > "$DIR/orig_fps"
  for k in $(rr_keys); do
    printf '%s=%s\n' "$k" "$(settings get system "$k" 2>/dev/null | tr -d '\r')" >> "$DIR/orig_fps"
  done
}

# fps_apply CAP [display-only]
fps_apply() {
  _cap=$1
  [ -f "$RATES" ] || save_rates
  fps_snapshot
  _em=$(eff_method "$_cap")
  if [ "$2" = "display-only" ] && [ ! -s "$FPSACT" ]; then echo display > "$FPSACT"
  elif [ "$2" != "display-only" ]; then echo "$_em" > "$FPSACT"; fi
  if [ "$_em" != gamemode ]; then
    _hz=$(pick_refresh "$_cap")
    for k in $(rr_keys); do settings put system "$k" "$_hz" >/dev/null 2>&1; done
  fi
  if [ "$2" != "display-only" ] && [ "$_em" != display ]; then
    _g=$(gm_fps "$_cap")
    for p in $PACKAGES; do
      pm path "$p" >/dev/null 2>&1 || continue
      cmd game set --mode 2 --fps "$_g" "$p" >/dev/null 2>&1
      cmd game mode 2 "$p" >/dev/null 2>&1
    done
  fi
}

fps_restore() {
  [ -f "$FPSACT" ] || return
  if [ -f "$DIR/orig_fps" ]; then
    while IFS== read -r k v; do
      [ -n "$k" ] || continue
      if [ -z "$v" ] || [ "$v" = "null" ]; then settings delete system "$k" >/dev/null 2>&1
      else settings put system "$k" "$v" >/dev/null 2>&1; fi
    done < "$DIR/orig_fps"
  fi
  _used=$(cat "$FPSACT" 2>/dev/null)
  if [ -n "$_used" ] && [ "$_used" != display ]; then
    for p in $PACKAGES; do
      pm path "$p" >/dev/null 2>&1 || continue
      cmd game reset "$p" >/dev/null 2>&1
      cmd game mode 1 "$p" >/dev/null 2>&1
    done
  fi
  rm -f "$FPSACT" "$CAPNOTE"
}

# Android's own refresh-rate overlay (SurfaceFlinger). Best effort: shows Hz, not frames.
ovl_on()  { setprop debug.sf.show_refresh_rate_overlay_render_rate 1 2>/dev/null; service call SurfaceFlinger 1034 i32 1 >/dev/null 2>&1; touch "$OVLACT"; }
ovl_off() { service call SurfaceFlinger 1034 i32 0 >/dev/null 2>&1; setprop debug.sf.show_refresh_rate_overlay_render_rate 0 2>/dev/null; rm -f "$OVLACT"; }

# ------------------------------------------------------- on-screen FPS overlay (app)
ovl_gravity() { case "$1" in tl) echo 51;; tc) echo 49;; tr) echo 53;; bl) echo 83;; br) echo 85;; *) echo 51;; esac; }

# Install / update the overlay app and give it the "draw over other apps" permission.
# Two routes: the module also ships it as a systemless system app (installed by Android at boot,
# works even when the ROM blocks shell installs). pm install is only the fallback.
OVL_INSTALL_LOG="$DIR/ovl_install.txt"
overlay_install() { # $1 = module dir
  _apk="$1/overlay/overlay.apk"
  if pm path "$OVL_PKG" >/dev/null 2>&1; then
    echo "installed: $(pm path "$OVL_PKG" | head -n1)" > "$OVL_INSTALL_LOG"
  else
    [ -f "$_apk" ] || { echo "overlay.apk missing in module" > "$OVL_INSTALL_LOG"; log "overlay: apk missing in module"; return 1; }
    _tmp=/data/local/tmp/codm_fps_overlay.apk
    cp "$_apk" "$_tmp" && chmod 644 "$_tmp"
    _out=$(pm install -r -d "$_tmp" 2>&1 | tr '\n' ' ')
    case "$_out" in
      *Success*) ;;
      *VERIFICATION*|*USER_RESTRICTED*|*canceled*|*Canceled*)
        # ROM asks for confirmation on shell installs: switch the check off for this one install
        _old=$(settings get global verifier_verify_adb_installs 2>/dev/null)
        settings put global verifier_verify_adb_installs 0 >/dev/null 2>&1
        _out2=$(pm install -r -d "$_tmp" 2>&1 | tr '\n' ' ')
        if [ -z "$_old" ] || [ "$_old" = null ]; then settings delete global verifier_verify_adb_installs >/dev/null 2>&1; else settings put global verifier_verify_adb_installs "$_old" >/dev/null 2>&1; fi
        _out="$_out | retry: $_out2";;
    esac
    case "$_out" in *Success*) ;; *) _out2=$(cmd package install -r -d "$_tmp" 2>&1 | tr '\n' ' '); _out="$_out | cmd package: $_out2";; esac
    rm -f "$_tmp"
    echo "$_out" > "$OVL_INSTALL_LOG"
    log "overlay install: $_out"
    pm path "$OVL_PKG" >/dev/null 2>&1 || { log "overlay app still missing - the system-app copy appears after the next reboot"; return 1; }
  fi
  appops set "$OVL_PKG" SYSTEM_ALERT_WINDOW allow >/dev/null 2>&1
  appops set "$OVL_PKG" RUN_IN_BACKGROUND allow >/dev/null 2>&1
  cmd deviceidle whitelist +"$OVL_PKG" >/dev/null 2>&1
  mkdir -p "$OVL_DIR" 2>/dev/null; chmod 755 "$OVL_DIR" 2>/dev/null
  return 0
}

overlay_start() {
  _g=$(ovl_gravity "$OVL_POS"); _a=$(( OVL_BG * 255 / 100 )); [ "$_a" -ge 128 ] && _a=$(( _a - 256 )); _bg=$(( _a * 16777216 ))  # ARGB as signed 32-bit: 100% = fully opaque
  mkdir -p "$OVL_DIR" 2>/dev/null; chmod 755 "$OVL_DIR" 2>/dev/null
  cmd deviceidle tempwhitelist -d 20000 "$OVL_PKG" >/dev/null 2>&1   # lets a background shell start the service
  _o=$(am startservice -n "$OVL_PKG/.OverlayService" --ei g "$_g" --ei x "$OVL_X" --ei y "$OVL_Y" --ei sz "$OVL_SIZE" --ei bg "$_bg" 2>&1 | tr '\n' ' ')
  echo "$_o" > "$DIR/ovl_start.txt"
  log "overlay start: $_o"
}
overlay_stop() { am force-stop "$OVL_PKG" >/dev/null 2>&1; rm -f "$OVL_FILE"; }
