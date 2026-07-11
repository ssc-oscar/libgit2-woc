#!/bin/bash
# distPar.sh -- parallel DiffCT STATS sampling for the depth/size distribution.
# Runs N streams over .cs sections (each a uniform sha sample), HEAD-capped, to accumulate ~100k
# measured commits fast; concatenates to diststat.all.txt. Run on da3 (base offset local, gen sidx
# via /da5_fast). Env: D (out dir), SECS (# sections), HEAD (commits/section), WOC bin.
set -u
D=${D:-/da8_data/update/V2605d}
SECS=${SECS:-8}
HEAD=${HEAD:-13000}
BIN=${BIN:-/da5_fast/bin/cmputeDiffGen}
LAYERED=/da5_fast/All.blobsGen
export D HEAD BIN LAYERED
one(){
  s=$1
  zcat "$D/V2604V2605.$s.cs" 2>/dev/null | head -"$HEAD" \
    | LAYERED="$LAYERED" STATS=1 STAT_MAX_NODES=20000 "$BIN" /fast/All.sha1o /data/All.blobs 2>/dev/null \
    > "$D/diststat.p$s.txt"
  echo "sec $s: $(wc -l < "$D/diststat.p$s.txt") measured"
}
export -f one
seq 0 $((SECS-1)) | xargs -P"$SECS" -I{} bash -c 'one "$@"' _ {}
cat "$D"/diststat.p*.txt > "$D/diststat.all.txt"
echo "DISTPAR_DONE $(date) total=$(wc -l < "$D/diststat.all.txt")"
