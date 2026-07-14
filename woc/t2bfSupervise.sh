#!/bin/bash
# t2bfSupervise.sh  -- RUN ON da5. Self-manages t2bf completion when output (~36.5T) exceeds
# da5:/fast (~21T): (1) continuously DRAIN completed t2bf.<sec>.gz to da8 (208T free) and delete
# local, freeing /fast; (2) keep the t2bf driver RUNNING (resumable) until all 128 sections done.
# Outbound (da5->da8 NFS ~110 MB/s) is the bottleneck, so this just runs until it finishes (~days).
set -u
SRC=/fast/All.blobsGen/t2bf
DST=${DST:-/da8_data/update/t2bf}; mkdir -p "$DST"
DRAIN_PAR=${DRAIN_PAR:-3}
LOG=/tmp/t2bf_build.log
export SRC DST
drain_one(){ s=$1; for f in "t2bf.$s.gz" "t2ctc.$s.gz" "unk.$s.gz"; do
    [ -f "$SRC/$f" ] || continue
    if cp "$SRC/$f" "$DST/.$f.tmp" 2>/dev/null && mv "$DST/.$f.tmp" "$DST/$f" 2>/dev/null; then rm -f "$SRC/$f"; fi
  done; echo "[drain $(date -u +%H:%M)] sec $s -> da8; /fast free=$(df -h /fast|awk 'NR==2{print $4}')"; }
export -f drain_one

# (1) background drainer: move every completed (.done) section whose .gz still sits on /fast
( while true; do
    for dn in "$SRC"/t2bf.*.done; do [ -f "$dn" ] || continue; s=$(basename "$dn" .done); s=${s#t2bf.}
      [ -f "$SRC/t2bf.$s.gz" ] && echo "$s"; done | sort -un | xargs -r -P"$DRAIN_PAR" -I{} bash -c 'drain_one "$@"' _ {}
    if grep -q "BUILD COMPLETE" "$LOG" 2>/dev/null && [ -z "$(ls "$SRC"/t2bf.*.gz 2>/dev/null)" ]; then echo "[drain] ALL DRAINED $(date -u)"; break; fi
    sleep 45
  done ) &
DPID=$!
echo "=== t2bfSupervise start $(date -u): drainer pid=$DPID, DST=$DST ==="

# (2) supervisor: (re)launch driver when stopped/wedged, undone sections remain, free>3T
prev_d=-1; stall=0
while true; do
  d=$(ls "$SRC"/t2bf.*.done 2>/dev/null | wc -l)
  if [ "$d" -ge 128 ]; then echo "=== t2bf ALL 128 DONE $(date -u); waiting for final drain ==="; break; fi
  workers=$(pgrep -fc t2bfBuild 2>/dev/null || echo 0)
  tmp=$(ls "$SRC"/*.gz.tmp 2>/dev/null | wc -l)
  fk=$(df -P /fast | awk 'NR==2{print $4+0}')
  # STALL: driver alive but 0 workers + 0 in-flight + no progress for 2 checks -> kill (resume below)
  if pgrep -f t2bfHost.sh >/dev/null 2>&1 && [ "${workers:-0}" -eq 0 ] && [ "$tmp" -eq 0 ] && [ "$d" -eq "$prev_d" ]; then
    stall=$((stall+1))
    if [ "$stall" -ge 2 ]; then
      echo "=== STALL: driver wedged at $d/128 -> kill+restart $(date -u) ==="
      pkill -9 -f t2bfHost.sh; pkill -9 -f 'xargs -P'; pkill -9 -f t2bfBuild; rm -f "$SRC"/*.gz.tmp; stall=0; sleep 3
    fi
  else stall=0; fi
  if ! pgrep -f t2bfHost.sh >/dev/null 2>&1; then
    if [ "$fk" -gt 3000000000 ]; then
      echo "=== resume driver: $d/128 done, /fast $(df -h /fast|awk 'NR==2{print $4}') free $(date -u) ==="
      cd /fast && setsid nohup bash /da5_fast/bin/t2bfHost.sh 16 >> "$LOG" 2>&1 </dev/null &
    else echo "=== waiting on drain: $d/128 done, only $(df -h /fast|awk 'NR==2{print $4}') free $(date -u) ==="; fi
  fi
  prev_d=$d
  sleep 120
done
# let drainer finish the tail
wait $DPID 2>/dev/null
echo "=== t2bfSupervise COMPLETE $(date -u): $(ls "$SRC"/t2bf.*.done 2>/dev/null|wc -l)/128 done, drained to $DST ==="
