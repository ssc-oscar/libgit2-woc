#!/bin/bash
# rootStallWatch.sh [stale_sec]  -- daemon: any root (137+) whose clone STALLS at the tail
# (STAGE=cloning, no clone.err write for >stale_sec, 0 live git clones) is auto-kicked into
# grabbing via kickRoot.sh. Covers all current+future cloning roots; skips those already
# grabbing/done. Runs until stopped.
set -u
STALE=${1:-2700}   # 45 min no clone progress = stalled tail
echo "=== rootStallWatch start $(date '+%F %T'); stale=${STALE}s ==="
while true; do
  for d in /media/volume/trees/V2605.*; do
    v=$(basename "$d" | grep -oE '[0-9]+'); [ -z "$v" ] && continue
    [ "$v" -ge 137 ] 2>/dev/null || continue          # roots only
    st=$(cat "$d/STAGE" 2>/dev/null | cut -d' ' -f1)
    [ "$st" = cloning ] || continue                    # only cloning ones
    ngit=0; for p in $(pgrep -x git); do case "$(readlink /proc/$p/cwd 2>/dev/null)" in *V2605.$v/*|*V2605.$v) ngit=$((ngit+1));; esac; done
    [ "$ngit" -gt 0 ] && continue                      # still actively cloning
    age=$(( $(date +%s) - $(stat -c %Y "$d/clone.err" 2>/dev/null || echo "$(date +%s)") ))
    if [ "$age" -gt "$STALE" ]; then
      echo "[$(date '+%F %T')] $v stalled (clone.err ${age}s stale, 0 git) -> kickRoot"
      bash /home/exouser/bin/kickRoot.sh "$v" 2>&1 | grep -vE 'No such file'
    fi
  done
  sleep 300
done
