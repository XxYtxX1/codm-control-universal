#!/system/bin/sh

cpu_info() {
  for p in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$p" ] || continue
    pol=${p##*/policy}
    cur=$(cat "$p/scaling_cur_freq" 2>/dev/null | head -n1)
    max=$(cat "$p/cpuinfo_max_freq" 2>/dev/null | head -n1)
    min=$(cat "$p/cpuinfo_min_freq" 2>/dev/null | head -n1)
    gov=$(cat "$p/scaling_governor" 2>/dev/null | head -n1)
    avail=$(cat "$p/scaling_available_governors" 2>/dev/null | tr ' ' ',')
    [ -n "$cur" ] || continue
    echo "cpu|$pol|${cur:-0}|${max:-0}|${min:-0}|${gov:-?}|${avail:-}"
  done
}

gpu_info() {
  for d in /sys/class/devfreq/*; do
    [ -d "$d" ] || continue
    name=${d##*/_
    case "$name" in *gpu*|*kgsl*|*mali*|*g*|*dpu*|*mdss*)  ;;
      *) continue;;
    esac
    cur=$(cat "$d/cur_freq" 2>/dev/null | head -n1)
    max=$(cat "$d/max_freq" 2>/dev/null | head -n1)
    min=$(cat "$d/min_freq" 2>/dev/null | head -n1)
    gov=$(cat "$d/governor" 2>/dev/null | head -n1)
    avail=$(cat "$d/available_governors" 2>/dev/null | tr ' ' ',')
    [ -n "$cur" ] || continue
    echo "gpu|$name|${cur:-0}|${max:-0}|${min:-0}|${gov:-?}|${avail:-}"
  done
}

set_gov() {
  node="$1"
  val="$2"
  [ -w "$node" ] || { echo "not-writable"; return 1; }
  avail=$(cat "${node%/*}/scaling_available_governors" 2>/dev/null || cat "${node%/*}/available_governors" 2>/dev/null)
  case " $avail " in *" $val "*) ;;
    *) echo "unsupported"; return 1;;
  esac
  printf '%s' "$val" > "$node" 2>/dev/null && echo "ok" || echo "write-failed"
}

case "$1" in
  cpu) cpu_info ;;
  gpu) gpu_info ;;
  all) cpu_info; gpu_info ;;
  setgov) set_gov "$2" "$3" ;;
esac
