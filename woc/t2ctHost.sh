#!/bin/bash
# t2ctHost.sh [P]  -- build the tree->child-tree (t2ct) map for all 128 sections, P-parallel,
# resumable. Per section: sequential t2ctBuild over base tree_<sec> + gen tree_<sec> -> pigz ->
# t2ct.<sec>.gz (edges "parent_tree;child_tree", sharded by PARENT sha = section). Sequential I/O;
# da5 /data is a RAID so parallelism scales (16-way ~729 MB/s ~= 17h for 45T). Frozen once built
# (extend per new gen). Consumer: isaac's closure BFS (seed trees -> children via t2ct joins).
set -u
P=${1:-16}
OUT=${OUT:-/fast/All.blobsGen/t2ct}; mkdir -p "$OUT"
BASE=${BASE:-/da5_data/All.blobs}
GEN=${GEN:-/fast/All.blobsGen/tree_gen1}
BIN=${BIN:-/da5_fast/bin/t2ctBuild}
export OUT BASE GEN BIN
echo "=== t2ctHost P=$P $(date) ==="
one(){
  s=$1
  [ -f "$OUT/t2ct.$s.done" ] && { echo "sec $s already done"; return 0; }
  { "$BIN" "$BASE/tree_$s.idx" "$BASE/tree_$s.bin"
    [ -s "$GEN/tree_$s.idx" ] && "$BIN" "$GEN/tree_$s.idx" "$GEN/tree_$s.bin"; } 2>>"$OUT/t2ct.$s.err" \
    | pigz -p2 > "$OUT/t2ct.$s.gz.tmp" && mv "$OUT/t2ct.$s.gz.tmp" "$OUT/t2ct.$s.gz" && touch "$OUT/t2ct.$s.done"
  echo "sec $s DONE $(date): $(zcat "$OUT/t2ct.$s.gz" | wc -l) edges"
}
export -f one
seq 0 127 | xargs -P"$P" -I{} bash -c 'one "$@"' _ {}
echo "=== t2ct BUILD COMPLETE $(date): $(ls "$OUT"/t2ct.*.done | wc -l)/128 ==="
