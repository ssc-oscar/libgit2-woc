#!/bin/bash
# loopFetchExo.sh <start> <step> <max> <ver> <DT>
# Self-advancing sequential loop: fetchExo on <start>, and when it finishes,
# advance +<step> and do the next, ... up to <max>. Run several of these in
# parallel with different <start> (e.g. 53..57 step 6) to cover a dataset range
# without overlap and stay N-wide. Dump disk is auto-picked (emptier of out/b).
set -u
start=${1:?usage: loopFetchExo.sh <start> <step> <max> <ver> <DT>}; step=${2:?}; max=${3:?}; ver=${4:?}; DT=${5:?}
m=$start
while [ "$m" -le "$max" ]; do
  mm=$(printf '%03d' "$m")
  if [ -f "/media/volume/trees/$ver.$mm/STAGE" ]; then
    echo "[loop$start] $ver.$mm already started (STAGE=$(cat /media/volume/trees/$ver.$mm/STAGE)); skipping"
  else
    o=$([ "$(df --output=avail /media/volume/out 2>/dev/null|tail -1)" -ge "$(df --output=avail /media/volume/b 2>/dev/null|tail -1)" ] && echo out || echo b)
    echo "[loop$start] start fetchExo $ver.$mm -> $o  $(date '+%F %T')"
    /home/exouser/bin/fetchExo.sh "$mm" "$ver" "$DT" "$o" || echo "[loop$start] fetchExo $ver.$mm FAILED $(date '+%F %T')"
    echo "[loop$start] done   $ver.$mm  $(date '+%F %T')"
  fi
  m=$((m+step))
done
echo "[loop$start] LOOP COMPLETE $(date '+%F %T')"
