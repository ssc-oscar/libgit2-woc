#!/bin/bash
# convertWStch.sh -- convert staged gatherWS bin+sidx WS shards -> content .tch (cmputeDiffGenFB
# format), per-shard verify (tch record count == sidx records), then delete bin+sidx. PAR parallel.
# Idempotent: a shard whose .tch already matches its sidx is just cleaned (bin+sidx removed).
set -u
WS=${WS:-/fast/All.blobsWS/V2605/tree_gen1}; BIN=${BIN:-/da5_fast/bin/sidx2tch}; PAR=${PAR:-4}
conv(){ s=$1
  [ -f "$WS/tree_$s.sidx" ] || return 0
  nsidx=$(( $(stat -c%s "$WS/tree_$s.sidx")/32 ))
  if [ -f "$WS/tree_$s.tch" ]; then
    ntch=$(tchmgr inform "$WS/tree_$s.tch" 2>/dev/null | grep -i "record number" | grep -o "[0-9]*")
    if [ "$nsidx" = "$ntch" ] && [ -n "$ntch" ]; then rm -f "$WS/tree_$s.bin" "$WS/tree_$s.sidx"; echo "sec $s already OK ($ntch), cleaned $(date -u)"; return 0; fi
  fi
  [ -f "$WS/tree_$s.bin" ] || { echo "sec $s: sidx but no bin (KEPT)"; return 0; }
  "$BIN" "$WS/tree_$s.sidx" "$WS/tree_$s.bin" "$WS/tree_$s.tch.tmp" 2>>"$WS/conv.$s.err" && mv "$WS/tree_$s.tch.tmp" "$WS/tree_$s.tch" || { echo "sec $s CONVERT FAIL"; return 0; }
  ntch=$(tchmgr inform "$WS/tree_$s.tch" 2>/dev/null | grep -i "record number" | grep -o "[0-9]*")
  if [ "$nsidx" = "$ntch" ] && [ -n "$ntch" ]; then rm -f "$WS/tree_$s.bin" "$WS/tree_$s.sidx"; echo "sec $s OK ($ntch recs), bin+sidx removed $(date -u)"
  else echo "sec $s VERIFY FAIL nsidx=$nsidx ntch=$ntch (KEPT) $(date -u)"; fi
}
export -f conv; export WS BIN
echo "=== convertWStch PAR=$PAR $(date -u) ==="
for s in $(seq 0 127); do
  while [ "$(jobs -rp|wc -l)" -ge "$PAR" ]; do sleep 2; done
  conv "$s" &
done
wait
echo "=== done: $(ls "$WS"/tree_*.tch 2>/dev/null|wc -l) .tch, $(ls "$WS"/tree_*.bin 2>/dev/null|wc -l) bin remaining, /fast $(df -h /fast|awk 'NR==2{print $4}') $(date -u) ==="
