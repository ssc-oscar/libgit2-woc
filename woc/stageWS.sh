#!/bin/bash
# stageWS.sh -- floor-guarded, resumable WS staging on da5 from the RESHARDED closure
# (/fast/closure2/closure.<sec>, sha[0]%128-sharded to match the object store). Builds
# $WS/tree_gen1/tree_<sec>.{bin,sidx}. Stops starting new sections when /fast drops under FLOOR_KB
# (leaves headroom while the t2bf backlog is draining). Per-sec .done => resumable + compatible
# with gatherWSHost.sh. PAR small (base reads are HDD; gatherWS offset-sorts each sec).
set -u
WS=${WS:-/fast/All.blobsWS/V2605}; BIN=${BIN:-/da5_fast/bin/gatherWS}
CL=${CL:-/fast/closure2}; FLOOR_KB=${FLOOR_KB:-838860800}   # ~800G floor
PAR=${PAR:-3}; SECS=${SECS:-$(seq 0 127)}
export LD_LIBRARY_PATH=/usr/local/lib PREO=/fast/All.sha1o BASEBIN=/data/All.blobs LAYERED=/fast/All.blobsGen VERIFY=
export WS BIN CL
mkdir -p "$WS/tree_gen1"
one(){ s=$1
  [ -f "$WS/.done.$s" ] && return 0
  [ -s "$CL/closure.$s" ] || { echo "sec $s: no input"; return 0; }
  t0=$(date +%s)
  if "$BIN" "$CL/closure.$s" "$WS" "$s" 2>>"$WS/stage.$s.err"; then
    touch "$WS/.done.$s"
    echo "sec $s DONE $(( $(date +%s)-t0 ))s bin=$(stat -c%s "$WS/tree_gen1/tree_$s.bin" 2>/dev/null)B /fast=$(df -h /fast|awk 'NR==2{print $4}') $(date -u)"
  else echo "sec $s FAILED"; fi
}
export -f one
echo "=== stageWS start PAR=$PAR floor=$((FLOOR_KB/1024/1024))G $(date -u) ==="
for s in $SECS; do
  [ -f "$WS/.done.$s" ] && continue
  fk=$(df -P /fast | awk 'NR==2{print $4+0}')
  if [ "$fk" -lt "$FLOOR_KB" ]; then echo "FLOORSTOP at sec $s (/fast $((fk/1024/1024))G < floor) $(date -u)"; break; fi
  while [ "$(jobs -rp | wc -l)" -ge "$PAR" ]; do sleep 3; done
  one "$s" &
done
wait
echo "=== stageWS end: $(ls "$WS"/.done.* 2>/dev/null | wc -l)/128 staged, /fast $(df -h /fast|awk 'NR==2{print $4}') free $(date -u) ==="
