#!/system/bin/sh
# Real FPS sampler. Reads what SurfaceFlinger actually presented for the game's layer:
#   method 1: per-frame present timestamps (dumpsys SurfaceFlinger --latency)
#   method 2: TimeStats frame counter (for ROMs where --latency returns no frames)
# Nothing is faked: FPS = frames actually presented to the screen per second.
MODDIR=${0%/*}
. "$MODDIR/common.sh"
mkdir -p "$DIR"

BB=$(find_bb) || { echo "no-awk" > "$FPSERR"; log "fps monitor: no busybox with awk found - monitor disabled"; exit 0; }

# stdin: output of `dumpsys SurfaceFlinger --latency <layer>`; arg prev: newest timestamp of previous sample
# Tolerant: a line with 1 number = refresh period, a line with 3 numbers = one frame.
# stdout: fps avg_ms worst_ms hz jank newest nframes
PARSE='
NF==1 && $1+0>1000000 && period==0 { period=$1+0; next }
NF==3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { t=$2+0; if (t>0 && t<9e18) a[++n]=t; next }
END {
  hz=(period>0)?int(1e9/period+0.5):0
  if (n<1) { printf "0 0 0 %d 0 %.0f 0 0 %.3f 0 %s\n", hz, prev, seenu, (om=="")?"":sprintf("%.0f",om); exit }
  nw=a[n]
  # clock offset (SurfaceFlinger time minus uptime): the largest value seen, so est is the real "now"
  # (the old estimate pinned the window end to the newest present and added one frame at steady rates)
  if (nw!=prev) { seen=nowu; cand=nw-nowu*1e9; if (om=="" || cand>om+0) om=cand } else seen=seenu
  if (om=="") om=nw-nowu*1e9
  # /proc/uptime is truncated to 10 ms, so the largest offset is ~10 ms too high: take the midpoint (5 ms)
  est=nowu*1e9+om-5000000
  oms=sprintf("%.0f",om)
  c=0; for (i=n;i>=1;i--) { if (a[i]>est-1e9) c++; else break }
  if (c<2) { printf "0 0 0 %d 0 %.0f 0 0 %.3f %.3f %s\n", hz, nw, seen, (est-nw)/1e6, oms; exit }
  first=n-c+1; span=a[n]-a[first]
  if (a[1]<=est-1e9) fps=c; else fps=(c-1)*1e9/span
  avg=span/(c-1); worst=0; jank=0
  for (j=first+1;j<=n;j++) { d=a[j]-a[j-1]; if (d>worst) worst=d; if (d>1.5*avg) jank++ }
  last=(n>=2)?(a[n]-a[n-1]):0
  printf "%.1f %.2f %.2f %d %d %.0f %d %.3f %.3f %.3f %s\n", fps, avg/1e6, worst/1e6, hz, jank, nw, n, last/1e6, seen, (est-nw)/1e6, oms
}'

# measure LAYER PREV_NEWEST PREV_SEEN_UPTIME -> fields (see PARSE); uptime is the sampler's own clock
measure() {
  read -r _nu _ < /proc/uptime
  dumpsys SurfaceFlinger --latency "$1" 2>/dev/null | tr -d '\r' | "$BB" awk -v prev="${2:-0}" -v seenu="${3:-0}" -v nowu="$_nu" -v om="${4:-}" "$PARSE"
}

# layers that are never the game
is_system_layer() {
  case "$1" in
    "Background for"*|"Bounds for"*|Task=*|ActivityRecord*|WindowToken*|Letterbox*|StatusBar*|NavigationBar*|"ScreenDecor"*|InputMethod*|"Wallpaper"*|"Splash Screen"*|*"com.android.systemui"*|*"com.android.launcher"*|*"com.codm.fps"*|"mBlastBufferQueue"*|"ImeContainer"*|"DisplayRotation"*|"Display "*|"Surface(name="*) return 0;;
  esac
  return 1
}

# Choose the layer that is really presenting frames for the game
LASTDBG=0
pick_layer() {
  _best=""; _bf="-1"; _seen=0; _cand=0
  dumpsys SurfaceFlinger --list 2>/dev/null | tr -d '\r' > "$DIR/.alllayers"
  _seen=$(wc -l < "$DIR/.alllayers" 2>/dev/null || echo 0)
  : > "$DIR/.layers"
  for p in $PKGS; do grep -F "$p" "$DIR/.alllayers" >> "$DIR/.layers"; done
  # nothing carries the package name? then try every non-system layer
  [ -s "$DIR/.layers" ] || cp "$DIR/.alllayers" "$DIR/.layers"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    is_system_layer "$l" && continue
    case "$l" in "Background for"*|"Bounds for"*|"Task="*|"ActivityRecord"*) continue;; esac
    _cand=$((_cand + 1))
    _m=$(measure "$l" 0); _f=${_m%% *}; _fi=${_f%%.*}
    [ -z "$_fi" ] && _fi=0
    if [ "$_fi" -gt "$_bf" ]; then _bf=$_fi; _best=$l; fi
  done < "$DIR/.layers"
  LAYER=$_best
  if [ -z "$LAYER" ] || [ "$_bf" -le 0 ]; then
    LAYER=""
    # leave a trail so Diagnostics shows why nothing was found (at most once a minute)
    _now=$(date +%s)
    if [ $((_now - LASTDBG)) -ge 60 ]; then
      LASTDBG=$_now
      if [ "$_seen" -le 1 ]; then echo "no-layers" > "$FPSERR"; log "fps: SurfaceFlinger --list returned $_seen layers (service call blocked?)"
      elif [ "$_cand" -eq 0 ]; then echo "no-layer-match" > "$FPSERR"; log "fps: no layer matched $PKGS; layers: $(head -n 8 "$DIR/.alllayers" | tr '\n' '|')"
      else echo "no-frames" > "$FPSERR"; log "fps: $_cand candidate layer(s) but none report frames; first: $(head -n 1 "$DIR/.layers")"; fi
    fi
  else
    rm -f "$FPSERR"; METHOD=lat; PREFER=lat
  fi
  rm -f "$DIR/.layers" "$DIR/.alllayers"
}


# ---- method 2: TimeStats. SurfaceFlinger keeps a per-layer counter of frames it presented.
# Newer Android versions no longer fill --latency, but this counter still works.
# FPS = counter delta / elapsed time. (Frame-time spikes/stutter are not available this way.)
TSPREV="$DIR/.tsprev"; TSNEW="$DIR/.tsnew"; TSLAY="$DIR/.tslayer"; TSHZ=0
ts_read() { # -> "layer<TAB>totalFrames" for the game's layers (matches layerName or packageName)
  dumpsys SurfaceFlinger --timestats -dump -maxlayers 100 2>/dev/null | tr -d '\r' | "$BB" awk -v pk="$PKGS" '
    BEGIN { n=split(pk, P, " ") }
    /^[ \t]*layerName[ \t]*=/ { cur=$0; sub(/^[^=]*=[ \t]*/, "", cur); curp=""; next }
    /^[ \t]*packageName[ \t]*=/ { curp=$0; sub(/^[^=]*=[ \t]*/, "", curp); next }
    /^[ \t]*totalFrames[ \t]*=/ {
      if (cur != "") {
        v=$0; sub(/^[^=]*=[ \t]*/, "", v); ok=(n==0)
        for (i=1;i<=n;i++) if (index(cur, P[i])>0 || index(curp, P[i])>0) ok=1
        if (ok && v ~ /^[0-9]+$/) print cur "\t" v
        cur=""; curp=""
      }
      next
    }'
}
ts_measure() { # -> same fields as measure(): fps avg_ms worst_ms hz jank newest nframes
  read _up _ < /proc/uptime
  ts_read > "$TSNEW"
  if [ -s "$TSPREV" ]; then
    _r=$("$BB" awk -v now="$_up" -v hz="${TSHZ:-0}" -v outf="$TSLAY" 'BEGIN { FS="\t" }
      FNR==1 && NR==FNR { tp=$1+0; next }
      NR==FNR { pf[$1]+=$2; next }
      { nf[$1]+=$2 }
      END {
        dt=now-tp; best=0; bl=""
        if (dt>0.2) for (k in nf) if (k in pf) { d=nf[k]-pf[k]; if (d>0) { f=d/dt; if (f>best) { best=f; bl=k } } }
        print bl > outf
        if (best<1) { printf "0 0 0 %d 0 0 0\n", hz; exit }
        printf "%.1f %.2f 0 %d 0 0 0\n", best, 1000/best, hz
      }' "$TSPREV" "$TSNEW")
  else
    _r="0 0 0 ${TSHZ:-0} 0 0 0"
  fi
  { echo "$_up"; cat "$TSNEW"; } > "$TSPREV"
  echo "$_r"
}
TSFAIL=0; PICKS=0
TSINIT=0
pick_ts() { # 0 = TimeStats reports frames for the game
  if [ $TSINIT -eq 0 ]; then dumpsys SurfaceFlinger --timestats -clear -enable >/dev/null 2>&1; TSINIT=1   # as in the Android docs
  else dumpsys SurfaceFlinger --timestats -enable >/dev/null 2>&1; fi
  rm -f "$TSPREV"; TSHZ=$(current_hz)
  ts_measure >/dev/null
  _i=0
  while [ $_i -lt 2 ]; do
    sleep 1
    _o=$(ts_measure)
    # shellcheck disable=SC2086
    set -- $_o
    case "${1:-0}" in
      0|0.0) _i=$((_i + 1));;
      *) METHOD=ts; LAYER="TimeStats"; PREFER=ts; PREV=0; TSFAIL=0
         rm -f "$FPSERR"; log "fps: using TimeStats counters ($(cat "$TSLAY" 2>/dev/null))"
         return 0;;
    esac
  done
  TSFAIL=$((TSFAIL + 1))
  return 1
}

# Raw evidence for the Diagnostics page, captured while the game is really on screen
# (the Diagnostics page is usually opened when the game is NOT running, so it can't see this).
LASTCAP=0
fps_capture() {
  _n=$(date +%s); [ $((_n - LASTCAP)) -ge 120 ] || return; LASTCAP=$_n
  _L=""; for p in $PKGS; do _L="$_L$(dumpsys SurfaceFlinger --list 2>/dev/null | tr -d '\r' | grep -F "$p")
"; done
  {
    echo "captured $(date '+%m-%d %H:%M:%S')  android=$(getprop ro.build.version.release) sdk=$(getprop ro.build.version.sdk) platform=$(getprop ro.board.platform)"
    echo "packages: $PKGS"
    echo "-- layers carrying the package name"
    printf '%s' "$_L" | grep -v '^$' | head -n 10
    echo "-- --latency (first 4 lines per layer)"
    printf '%s' "$_L" | grep -v '^$' | head -n 4 | while IFS= read -r _l; do echo "[$_l]"; dumpsys SurfaceFlinger --latency "$_l" 2>&1 | head -n 4; done
    echo "-- timestats"
    _t=$(dumpsys SurfaceFlinger --timestats -dump -maxlayers 100 2>&1 | tr -d '\r')
    echo "lines=$(printf '%s\n' "$_t" | wc -l); first: $(printf '%s\n' "$_t" | head -n 3 | tr '\n' '|')"
    printf '%s\n' "$_t" | grep -E '^[[:space:]]*(layerName|packageName|totalFrames) *=' | head -n 45
  } > "$DIR/fps_debug.txt" 2>&1
}

# Try the preferred method first, then the other one
pick_source() {
  PICKS=$((PICKS + 1)); _try_ts=1
  # the TimeStats check sleeps ~2 s: when the layer scan is the primary method, run it only every 8th pick
  # so a game layer that appears is found within 0.25 s (TimeStats-first devices keep their order)
  if [ "$PREFER" != ts ] && [ $((PICKS % 8)) -ne 0 ]; then _try_ts=0; fi
  if [ "$PREFER" = ts ] && [ $_try_ts -eq 1 ]; then
    pick_ts || pick_layer
  else
    pick_layer
    [ -n "$LAYER" ] || { [ $_try_ts -eq 1 ] && pick_ts; }
  fi
  [ -n "$LAYER" ] || fps_capture
  echo "$METHOD" > "$DIR/fps_method" 2>/dev/null
}

finish_session() {
  _n=$(wc -l < "$SESS" 2>/dev/null || echo 0)
  if [ "$_n" -ge 3 ]; then
    _cap=0; [ "$(cfg_get FPS_LOCK)" = 1 ] && _cap=$(cfg_get FPS_CAP)
    sort -n "$SESS" | "$BB" awk -v cap="${_cap:-0}" '
      { v[NR]=$1; s+=$1 }
      END { p=int(NR*0.01); if (p<1) p=1
            printf "secs=%d\navg=%.1f\nmin=%.1f\nmax=%.1f\np1=%.1f\ncap=%d\n", NR, s/NR, v[1], v[NR], v[p], cap }' > "$LASTSESS.t" && mv "$LASTSESS.t" "$LASTSESS"
    log "session: $(tr '\n' ' ' < "$LASTSESS")"
  fi
  rm -f "$SESS"
}

# median of three integers (a single odd second cannot move the number)
med3() {
  _a=$1; _b=$2; _c=$3
  if [ "$_a" -gt "$_b" ]; then _t=$_a; _a=$_b; _b=$_t; fi
  if [ "$_b" -gt "$_c" ]; then _t=$_b; _b=$_c; _c=$_t; fi
  if [ "$_a" -gt "$_b" ]; then _t=$_a; _a=$_b; _b=$_t; fi
  echo "$_b"
}

# color for the number (fps_int, ref = cap when the lock is on, else panel Hz)
# green >= 90% of ref, amber >= 70%, red below. No frames (0) is grey, never red.
fps_color() {
  _r=${2:-0}
  [ "$1" -gt 0 ] || { echo "#8e98a8"; return; }
  [ "$_r" -gt 0 ] || { echo "#39d98a"; return; }
  if [ $(( $1 * 100 )) -ge $(( _r * 90 )) ]; then echo "#39d98a"
  elif [ $(( $1 * 100 )) -ge $(( _r * 70 )) ]; then echo "#ffb020"
  else echo "#ff5d5d"; fi
}

# Write the text the overlay app shows (simple HTML)
write_overlay() { # fps(shown) ft worst hz jank
  [ "$FPS_OVERLAY" = 1 ] || return
  [ -d "$OVL_DIR" ] || return
  _fi=${1%%.*}; [ -z "$_fi" ] && _fi=0
  if [ "$FPS_LOCK" = 1 ] && [ -f "$FPSACT" ]; then _ref=$FPS_CAP; else _ref=${4:-0}; fi
  _c=$(fps_color "$_fi" "$_ref")
  _j=${5:-0}; _jc="#8e98a8"
  if [ "$_j" -ge 4 ] 2>/dev/null; then _jc="#ff5d5d"; elif [ "$_j" -ge 1 ] 2>/dev/null; then _jc="#ffb020"; fi
  if [ "$OVL_STYLE" = compact ]; then
    printf '<font color="%s"><b>%s</b></font> FPS &middot; %s ms' "$_c" "$_fi" "$2" > "$OVL_FILE.t"
  else
    if [ "$METHOD" = ts ]; then
      printf '<font color="%s"><b>%s</b></font> FPS<br>%s ms avg<br>%s Hz' "$_c" "$_fi" "$2" "$4" > "$OVL_FILE.t"
    else
      printf '<font color="%s"><b>%s</b></font> FPS<br>%s ms &middot; max %s<br>%s Hz &middot; <font color="%s">stutter %s</font>' "$_c" "$_fi" "$2" "$3" "$4" "$_jc" "${5:-0}" > "$OVL_FILE.t"
    fi
  fi
  mv "$OVL_FILE.t" "$OVL_FILE" 2>/dev/null; chmod 644 "$OVL_FILE" 2>/dev/null
}

# webroot/live.json: the WebUI reads this every ~150 ms (no shell per request)
publish_json() { # INGAME FPS FT WORST HZ HZNOW JANK LAYER METHOD FRAMEMS CAPN FRAMEAGE
  _j="$MODDIR/webroot/live.json"
  printf '{"ts":%s,"inGame":%s,"fps":%s,"ft":%s,"worst":%s,"hz":%s,"hzNow":%s,"jank":%s,"layer":"%s","method":"%s","frameMs":%s,"capNote":%s,"frameAge":%s}\n' \
    "${TSNOW:-$(date +%s)}" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" > "$_j.t" 2>/dev/null && mv "$_j.t" "$_j" 2>/dev/null
}

LAYER=""; PREV=0; TICK=0; PKGS=""; WRITES=0; STEP=1; HZ=0; PEAK=0; NOFR=0; METHOD=""; PREFER=lat
F1=0; F2=0; F3=0; LASTOK=0; FPSRAW=0; OVER=0; NOTED=0
SEENU=0; LASTSEC=""; HZNOW=0; CAPN=0; TSNOW=""; NOLAYER=0
FPS_OVERLAY=0; FPS_LOCK=0; FPS_CAP=60; OVL_STYLE=full
rm -f "$LIVE" "$FPSERR"
while true; do
  if [ ! -f "$INGF" ] || [ "$(cfg_get FPS_MONITOR)" = "0" ]; then
    [ -f "$SESS" ] && finish_session
    rm -f "$LIVE" "$HIST" "$TSPREV"; LAYER=""; METHOD=""; PREV=0; SEENU=0; TICK=0; PEAK=0; publish_json 0 0 0 0 0 0 0 "" "" 0 0 0
    _t=$(cat "$OVLTEST" 2>/dev/null); case "$_t" in ""|*[!0-9]*) _t=0;; esac
    [ "$(date +%s)" -lt "$_t" ] || rm -f "$OVL_FILE"     # keep the sample while "Test overlay" is running
    [ "$(cfg_get FPS_MONITOR)" = "0" ] && echo "monitor-off" > "$FPSERR" || rm -f "$FPSERR"
    sleep 2; continue
  fi

  if [ $((TICK % 6)) -eq 0 ]; then
    PKGS=$(cfg_get PACKAGES); [ -n "$PKGS" ] || PKGS="$DEF_PACKAGES"
    FPS_OVERLAY=$(cfg_get FPS_OVERLAY); [ -n "$FPS_OVERLAY" ] || FPS_OVERLAY=1
    FPS_LOCK=$(cfg_get FPS_LOCK); FPS_CAP=$(cfg_get FPS_CAP); [ -n "$FPS_CAP" ] || FPS_CAP=60
    OVL_STYLE=$(cfg_get OVL_STYLE); [ -n "$OVL_STYLE" ] || OVL_STYLE=full
    STEP=0.12
  fi
  # (re)select the layer when we have none, or every 20 ticks
  if [ -z "$LAYER" ] || { [ "$METHOD" = lat ] && [ $((TICK % 170)) -eq 0 ]; }; then
    _pl=$LAYER; pick_source
    [ "$LAYER" = "$_pl" ] || OMAX=""      # a new layer has its own clock offset: learn it again
  fi

  if [ -z "$LAYER" ]; then
    printf 'fps=0\nft=0\nworst=0\nhz=%s\njank=0\nlayer=\nmethod=\nts=%s\n' "$(current_hz)" "$(date +%s)" > "$LIVE.t" && mv "$LIVE.t" "$LIVE"
    # keep the counter visible so you can tell the overlay itself works and only the data is missing
    if [ "$FPS_OVERLAY" = 1 ] && [ -d "$OVL_DIR" ]; then
      printf '<font color="#ffb020"><b>--</b></font> FPS &middot; no data' > "$OVL_FILE.t" && mv "$OVL_FILE.t" "$OVL_FILE" 2>/dev/null; chmod 644 "$OVL_FILE" 2>/dev/null
    fi
    publish_json 1 0 0 0 "$HZ" "${HZNOW:-0}" 0 "" "" 0 0 0
    TICK=$((TICK + 1)); NOLAYER=$((NOLAYER + 1)); if [ "$NOLAYER" -lt 12 ]; then sleep 0.25; else sleep 0.5; fi; continue
  fi

  NOLAYER=0
  if [ "$METHOD" = ts ]; then
    [ $((TICK % 10)) -eq 0 ] && TSHZ=$(current_hz)
    OUT=$(ts_measure)
  else
    OUT=$(measure "$LAYER" "$PREV" "$SEENU" "$OMAX")
  fi
  # shellcheck disable=SC2086
  set -- $OUT
  FPS=${1:-0}; FT=${2:-0}; WORST=${3:-0}; HZ=${4:-0}; JANK=${5:-0}; NEW=${6:-0}; NFR=${7:-0}; LASTF=${8:-0}; SEEN=${9:-0}; FAGE=${10:-0}; OMAX=${11:-$OMAX}
  case "$HZ" in ''|*[!0-9]*) HZ=0;; esac
  _ri=${FPS%%.*}; case "$_ri" in ''|*[!0-9]*) _ri=0;; esac
  # nothing can be presented faster than the panel's top rate: such a number is a sampling glitch
  if [ "$HZ" -gt 0 ] && [ "$_ri" -gt $(( HZ + HZ / 20 + 1 )) ]; then _ri=$LASTOK; fi
  [ "$_ri" -gt 0 ] && LASTOK=$_ri
  if [ "$_ri" -eq 0 ]; then NOFR=$((NOFR + 1)); [ "$NOFR" -ge 25 ] && { LAYER=""; NOFR=0; }   # ~3 s with no frames: look for the game layer again
  else NOFR=0; fi
  PREV=$NEW; SEENU=$SEEN
  FPS=$_ri; FPSRAW=$_ri          # no smoothing: frames presented in the last second, as of now

  # cap check: with the lock on, frames far above the cap mean the ROM is not holding it (about 3 s to decide)
  CAPN=0
  if [ "$FPS_LOCK" = 1 ] && [ -f "$FPSACT" ]; then
    if [ "$_ri" -gt $(( FPS_CAP + FPS_CAP / 10 + 3 )) ]; then OVER=$((OVER + 1)); else OVER=0; fi
    if [ "$OVER" -ge 25 ]; then
      CAPN=$_ri; echo "$_ri" > "$CAPNOTE"
      [ "$NOTED" = 1 ] || { NOTED=1; log "fps cap $FPS_CAP not held: measuring about $_ri fps"; }
    else [ -f "$CAPNOTE" ] && rm -f "$CAPNOTE"; NOTED=0; fi
  else OVER=0; NOTED=0; [ -f "$CAPNOTE" ] && rm -f "$CAPNOTE"; fi

  # once per second: graph history, last-session stats, panel Hz now
  read -r _up _ < /proc/uptime; _sec=${_up%%.*}
  if [ "$_sec" != "$LASTSEC" ]; then
    LASTSEC=$_sec; TSNOW=$(date +%s)
    echo "$FPSRAW" >> "$HIST"
    case "$FPSRAW" in 0) ;; *) echo "$FPSRAW" >> "$SESS";; esac
    HZNOW=$(current_hz)
  fi

  LY=$LAYER; [ "$METHOD" = ts ] && LY=$(cat "$TSLAY" 2>/dev/null)
  _lq=$(printf '%s' "$LY" | tr -d '"\\')
  printf 'fps=%s\nraw=%s\nft=%s\nworst=%s\nhz=%s\njank=%s\nlayer=%s\nmethod=%s\nts=%s\nframe=%s\nhzn=%s\nfage=%s\n' "$FPS" "$FPSRAW" "$FT" "$WORST" "$HZ" "$JANK" "$LY" "$METHOD" "${TSNOW:-$_sec}" "$LASTF" "${HZNOW:-0}" "${FAGE:-0}" > "$LIVE.t" && mv "$LIVE.t" "$LIVE"
  publish_json 1 "$FPS" "$FT" "$WORST" "$HZ" "${HZNOW:-0}" "$JANK" "$_lq" "$METHOD" "$LASTF" "$CAPN" "$FAGE"
  write_overlay "$FPS" "$FT" "$WORST" "$HZ" "$JANK"

  WRITES=$((WRITES + 1))
  if [ $((WRITES % 120)) -eq 0 ]; then tail -n 120 "$HIST" > "$HIST.t" && mv "$HIST.t" "$HIST"; fi

  TICK=$((TICK + 1))
  if [ "$METHOD" = ts ]; then sleep 1; else sleep $STEP; fi
done
