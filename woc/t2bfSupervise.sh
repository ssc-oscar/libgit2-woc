#!/bin/bash
# t2bfSupervise.sh  -- RUN ON da5. Completes t2bf when output (~36.5T) exceeds da5:/fast (~21T):
#  (1) background DRAINER: continuously move completed t2bf.<sec>.gz to da8 (208T), delete local.
#  (2) foreground RUNNER loop: run one t2bfHost.sh PASS (job-pool; produces what fits, DISKSKIPs the
#      rest, then EXITS), gated on free space; repeat until 128 done. No pgrep-based liveness (it gave
#      false positives + self-matches) -- each pass is a plain foreground child we `wait` on.
set -u
SRC=/fast/All.blobsGen/t2bf
DST=${DST:-/da8_data/update/t2bf}; mkdir -p "$DST"
DRAIN_PAR=${DRAIN_PAR:-3}; export SRC DST
drain_one(){ s=$1; for f in "t2bf.$s.gz" "t2ctc.$s.gz" "unk.$s.gz"; do
    [ -f "$SRC/$f" ] || continue
    if cp "$SRC/$f" "$DST/.$f.tmp" 2>/dev/null && mv "$DST/.$f.tmp" "$DST/$f" 2>/dev/null; then rm -f "$SRC/$f"; fi
  done; echo "[drain $(date -u +%H:%M)] sec $s -> da8; /fast free=$(df -h /fast|awk 'NR==2{print $4}')"; }
export -f drain_one

( while true; do                                    # (1) drainer
    for dn in "$SRC"/t2bf.*.done; do [ -f "$dn" ] || continue; s=$(basename "$dn" .done); s=${s#t2bf.}
      [ -f "$SRC/t2bf.$s.gz" ] && echo "$s"; done | sort -un | xargs -r -P"$DRAIN_PAR" -I{} bash -c 'drain_one "$@"' _ {}
    [ -f "$SRC/.allbuilt" ] && [ -z "$(ls "$SRC"/t2bf.*.gz 2>/dev/null)" ] && { echo "[drain] ALL DRAINED $(date -u)"; break; }
    sleep 45
  done ) & DPID=$!
echo "=== t2bfSupervise start $(date -u): drainer=$DPID DST=$DST ==="

while true; do                                      # (2) runner
  d=$(ls "$SRC"/t2bf.*.done 2>/dev/null | wc -l)
  if [ "$d" -ge 128 ]; then touch "$SRC/.allbuilt"; echo "=== ALL 128 DONE $(date -u); awaiting final drain ==="; break; fi
  fk=$(df -P /fast | awk 'NR==2{print $4+0}')
  if [ "$fk" -lt 3000000000 ]; then echo "=== runner wait: $d/128 done, only $(df -h /fast|awk 'NR==2{print $4}') free -> draining $(date -u) ==="; sleep 180; continue; fi
  echo "=== RUN PASS: $d/128 done, $(df -h /fast|awk 'NR==2{print $4}') free $(date -u) ==="
  bash /da5_fast/bin/t2bfHost.sh 16 >> /tmp/t2bf_build.log 2>&1     # one pass, foreground, we wait on it
  echo "=== pass ended: $(ls "$SRC"/t2bf.*.done 2>/dev/null|wc -l)/128 done $(date -u) ==="
  sleep 10
done
wait $DPID 2>/dev/null
echo "=== t2bfSupervise COMPLETE $(date -u): $(ls "$SRC"/t2bf.*.done 2>/dev/null|wc -l)/128, drained to $DST ==="
