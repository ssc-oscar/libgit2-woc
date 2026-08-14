#!/bin/bash
# diffRun.sh -- V2605-V2604 commit diffs on da5 (cmputeDiffGenFB). Per shard: zcat .cs commit shas
# -> FB (staged SSD content .tch primary: tree_<sec>.tch base-resident closure trees + commit_<sec>.tch
# symlinked All.sha1c base commits; LAYERED gens for gen commits/trees; offset+base HDD residual)
# -> gzip c2fbb increment. PAR-parallel across the 128 sha-sections. Resumable (.done/shard).
# NOCOMMIT (delta commits not yet in base/gen -- task#8 gen incomplete) are skipped+logged in .err,
# collected to nocommit.<sec> for a later rerun once the gen is complete.
set -u
C=${C:-/fast/All.blobsWS/V2605/tree_gen1}
CS=${CS:-/da8_data/update/V2605d}
OUT=${OUT:-/fast/All.blobsWS/V2605/diffout}; mkdir -p "$OUT"
BIN=/da5_fast/bin/cmputeDiffGenFB
export LAYERED=/fast/All.blobsGen
PAR=${PAR:-24}
one(){ s=$1
  local cs="$CS/V2604V2605.$s.cs" ps t0
  [ -f "$cs" ] || { echo "sec $s: no .cs"; return 0; }
  [ -f "$OUT/diff.$s.done" ] && return 0
  t0=$(date +%s)
  WOC_FBLOG="$OUT/fb.$s.log" zcat "$cs" 2>/dev/null | "$BIN" "$C" /fast/All.sha1o /data/All.blobs 2>"$OUT/diff.$s.err" | gzip > "$OUT/diff.$s.gz.tmp"
  ps=("${PIPESTATUS[@]}")
  if [ "${ps[1]:-1}" -eq 0 ]; then
    mv "$OUT/diff.$s.gz.tmp" "$OUT/diff.$s.gz"
    grep '^no commit' "$OUT/diff.$s.err" 2>/dev/null | awk '{print $3}' > "$OUT/nocommit.$s"
    touch "$OUT/diff.$s.done"
    echo "sec $s DONE $(( ($(date +%s)-t0)/60 ))m diffs=$(zcat "$OUT/diff.$s.gz"|wc -l) nocommit=$(wc -l < "$OUT/nocommit.$s") $(date -u)"
  else echo "sec $s FAILED (rc=${ps[*]})"; fi
}
export -f one; export C CS OUT BIN LAYERED
echo "=== diffRun PAR=$PAR $(date -u) content=$C ==="
for s in $(seq 0 127); do
  while [ "$(jobs -rp|wc -l)" -ge "$PAR" ]; do sleep 5; done
  one "$s" &
done
wait
echo "=== diffRun END $(date -u): $(ls "$OUT"/diff.*.done 2>/dev/null|wc -l)/128 done, total nocommit=$(cat "$OUT"/nocommit.* 2>/dev/null|wc -l) ==="
