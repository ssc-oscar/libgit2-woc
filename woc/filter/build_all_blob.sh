#!/bin/bash
set -u
OUT=/fast/blobFilters; mkdir -p "$OUT"; P=${P:-3}
build_one(){
  local X=$1 idx=/data/All.blobs/blob_$1.idx
  [ -f "$idx" ] || { echo "MISSING $idx"; return; }
  [ -s "$OUT/blob_$X.bf" ] && { echo "skip $X (exists)"; return; }
  if nice -n 19 ionice -c3 sh -c "perl /tmp/extract_sha.pl '$idx' | /tmp/build_bf '$OUT/blob_$X.bf.tmp'" 2>>"$OUT/build.err"; then
    mv -f "$OUT/blob_$X.bf.tmp" "$OUT/blob_$X.bf"; echo "done $X $(date +%T)"
  else echo "FAIL $X"; rm -f "$OUT/blob_$X.bf.tmp"; fi
}
export -f build_one; export OUT
echo "START $(date) P=$P"
seq 0 127 | xargs -P"$P" -I{} bash -c 'build_one "$@"' _ {}
echo "ALL DONE $(date); filters=$(ls $OUT/blob_*.bf 2>/dev/null|wc -l) size=$(du -sh $OUT 2>/dev/null|cut -f1)"
