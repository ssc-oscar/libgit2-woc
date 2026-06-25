#!/bin/bash
# loopFetchExo.sh <start> <step> <max> <ver> <DT>
# Self-advancing sequential loop: fetchExo on <start>, and when it finishes,
# advance +<step> and do the next, ... up to <max>. Run several of these in
# parallel with different <start> (e.g. 53..57 step 6) to cover a dataset range
# without overlap and stay N-wide. Dump disk = deterministic interleave: odd m -> out,
# even m -> b (with a >=97%-full fallback to the other disk to avoid ENOSPC corruption).
set -u
start=${1:?usage: loopFetchExo.sh <start> <step> <max> <ver> <DT>}; step=${2:?}; max=${3:?}; ver=${4:?}; DT=${5:?}
m=$start
while [ "$m" -le "$max" ]; do
  mm=$(printf '%03d' "$m")
  if [ -f "/media/volume/trees/$ver.$mm/STAGE" ]; then
    echo "[loop$start] $ver.$mm already started (STAGE=$(cat /media/volume/trees/$ver.$mm/STAGE)); skipping"
  else
    # deterministic interleave: odd dataset -> out, even -> b (keeps both disks balanced)
    o=$([ $((10#$mm % 2)) -eq 1 ] && echo out || echo b)
    # safety: if the chosen disk is >=97% full, fall back to the other (never write into a near-full fs)
    [ "$(df --output=pcent /media/volume/$o 2>/dev/null|tr -dc 0-9)" -ge 97 ] && o=$([ "$o" = out ] && echo b || echo out)
    echo "[loop$start] start fetchExo $ver.$mm -> $o  $(date '+%F %T')"
    /home/exouser/bin/fetchExo.sh "$mm" "$ver" "$DT" "$o" || echo "[loop$start] fetchExo $ver.$mm FAILED $(date '+%F %T')"
    echo "[loop$start] done   $ver.$mm  $(date '+%F %T')"
  fi
  m=$((m+step))
done
echo "[loop$start] LOOP COMPLETE $(date '+%F %T')"
