#!/bin/bash
# convgen_after.sh -- convert un-split da8 grab batches into per-sec main-store
# shards and build the read-side indexes AFTER, in two phases:
#
#   phase 1 (append): convgen folds each batch's objects (verbatim LZF bytes)
#                     into <out>/<type>_<sec>.{bin,idx}  (existing store format)
#   phase 2 (index):  for each touched sec, build the frozen offset index
#                     (.sidx) and the binary-fuse filter (.bf) ONCE from the
#                     final, larger .idx -- not per batch.
#
# The base is never mutated: <out> is a NEW generation; reads fall through
# (BF -> this gen's .sidx -> base). AllUpdateObj is never invoked.
#
#   convgen_after.sh <type> <out> <batch-prefix>...
#     <batch-prefix> = .../New<MAP>V<VER>.<NNN>.<SS>   (so .<type>.idx/.bin append)
#
# Env: BIN dir holding convgen, sidx, build_bf, extract_sha.pl (default: this dir),
#      P = parallelism for phase 2 (default 4).
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
BIN=${BIN:-$DIR}
P=${P:-4}
TYPE=${1:?usage: convgen_after.sh <type> <out> <batch-prefix>...}; shift
OUT=${1:?need <out>}; shift
[ $# -ge 1 ] || { echo "need at least one batch prefix"; exit 2; }
mkdir -p "$OUT"

echo "=== phase 1: append $# batch(es) -> $OUT ($TYPE) ==="
for b in "$@"; do
  i="$b.$TYPE.idx"; n="$b.$TYPE.bin"
  [ -s "$i" ] && [ -s "$n" ] || { echo "skip $b (missing $TYPE idx/bin)"; continue; }
  "$BIN/convgen" "$TYPE" "$i" "$n" "$OUT"
done

echo "=== phase 2: build .sidx + .bf per touched sec (P=$P) ==="
build_sec(){
  local idx=$1 base=${1%.idx}
  "$BIN/sidx" build "$idx" "$base.sidx" 2>>"$OUT/index.err"
  perl "$BIN/extract_sha.pl" "$idx" | "$BIN/build_bf" "$base.bf" 2>>"$OUT/index.err" >/dev/null
  echo "indexed $(basename "$base")"
}
export -f build_sec; export BIN OUT
ls "$OUT"/${TYPE}_*.idx 2>/dev/null | xargs -P"$P" -I{} bash -c 'build_sec "$@"' _ {}
echo "=== done: $(ls $OUT/${TYPE}_*.bin 2>/dev/null|wc -l) sec shards, $(ls $OUT/${TYPE}_*.sidx 2>/dev/null|wc -l) sidx, $(ls $OUT/${TYPE}_*.bf 2>/dev/null|wc -l) bf ==="
