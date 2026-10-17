#!/system/bin/sh
# Conservative CPU/GPU frequency ceiling controller. Only writes nodes that exist and
# accept the requested value; snapshots originals once and restores them on exit.
MODDIR=${0%/*}; . "$MODDIR/common.sh"
SNAP="$DIR/.cpugpu_snapshot"; STATE="$DIR/cpugpu_status"
numfile(){ [ -r "$1" ] && cat "$1" 2>/dev/null | grep -Eo '^[0-9]+' | head -n1; }
restore_cpu_gpu(){
  [ -f "$SNAP" ] || { rm -f "$STATE"; return; }
  while IFS='|' read -r node val; do
    case "$node" in /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq|/sys/class/devfreq/*/max_freq) [ -w "$node" ] && printf '%s' "$val" > "$node" 2>/dev/null;; esac
  done < "$SNAP"
  rm -f "$SNAP"; echo 'active=0' > "$STATE"; log 'CPU/GPU ceilings restored'
}
apply_cpu_gpu(){
  mode=$(cfg_get CPU_GPU_PROFILE); case "$mode" in balanced) pct=85;; performance) pct=100;; *) pct=85;; esac
  [ -f "$SNAP" ] || : > "$SNAP"
  found=0; changed=0
  for node in /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq /sys/class/devfreq/*/max_freq; do
    [ -f "$node" ] && [ -w "$node" ] || continue
    cur=$(numfile "$node"); [ -n "$cur" ] || continue
    # Snapshot only original value; never overwrite it on profile changes.
    grep -Fq "$node|" "$SNAP" || printf '%s|%s\n' "$node" "$cur" >> "$SNAP"
    found=$((found+1))
    # Base profile on the hardware's advertised maximum, not the already-applied ceiling.
    if [ "${node##*/}" = scaling_max_freq ]; then
      base="${node%/*}/cpuinfo_max_freq"
      [ -r "$base" ] && cur=$(numfile "$base")
      opp="${node%/scaling_max_freq}/scaling_available_frequencies"
    else
      opp="${node%/max_freq}/available_frequencies"
    fi
    [ -n "$cur" ] || cur=$(numfile "$node")
    target=$((cur*pct/100))
    # Use available OPP values where the kernel provides them; choose highest <= target.
    if [ -r "$opp" ]; then
      best=0; for f in $(cat "$opp" 2>/dev/null); do case "$f" in *[!0-9]*|'') continue;; esac; [ "$f" -le "$target" ] 2>/dev/null && [ "$f" -gt "$best" ] && best=$f; done
      [ "$best" -gt 0 ] && target=$best
    fi
    [ "$target" -gt 0 ] || continue
    if printf '%s' "$target" > "$node" 2>/dev/null; then changed=$((changed+1)); fi
  done
  if [ "$found" -eq 0 ]; then echo 'active=0' > "$STATE"; echo 'message=no-supported-frequency-nodes' >> "$STATE"; return 1; fi
  echo "active=1" > "$STATE"; echo "profile=$mode" >> "$STATE"; echo "nodes=$found" >> "$STATE"; echo "writes=$changed" >> "$STATE"
  log "CPU/GPU profile $mode: nodes=$found accepted-writes=$changed"
}
case "$1" in apply) apply_cpu_gpu;; restore) restore_cpu_gpu;; esac
