#!/bin/bash
# build_all_type.sh <blob|commit|tree> [P]  -- build 128 binary-fuse filters
# from /data/All.blobs/<type>_<sec>.idx into /fast/<type>Filters/ (resumable).
set -u
TYPE=${1:?usage: build_all_type.sh <blob|commit|tree> [P]}; P=${2:-3}
OUT=/fast/${TYPE}Filters; mkdir -p "$OUT"
build_one(){
  local X=$1 idx=/data/All.blobs/${TYPE}_$1.idx
  [ -f "$idx" ] || { echo "MISSING $idx"; return; }
  [ -s "$OUT/${TYPE}_$X.bf" ] && { echo "skip $TYPE $X"; return; }
  if nice -n 19 ionice -c3 sh -c "perl /tmp/extract_sha.pl '$idx' | /tmp/build_bf '$OUT/${TYPE}_$X.bf.tmp'" 2>>"$OUT/build.err"; then
    mv -f "$OUT/${TYPE}_$X.bf.tmp" "$OUT/${TYPE}_$X.bf"; echo "done $TYPE $X $(date +%T)"
  else echo "FAIL $TYPE $X"; rm -f "$OUT/${TYPE}_$X.bf.tmp"; fi
}
export -f build_one; export OUT TYPE
echo "START $TYPE $(date) P=$P"
seq 0 127 | xargs -P"$P" -I{} bash -c 'build_one "$@"' _ {}
echo "ALL DONE $TYPE $(date); filters=$(ls $OUT/${TYPE}_*.bf 2>/dev/null|wc -l) size=$(du -sh $OUT 2>/dev/null|cut -f1)"
