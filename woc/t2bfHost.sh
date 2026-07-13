#!/bin/bash
# t2bfHost.sh [P]  -- build t2bf (tree->blob;filename) for all 128 sections, base+gen, P-parallel,
# resumable. RUN ON da5 (tree store local; sequential reads). Per section, base then gen append.
# Outputs per section in $OUT:
#   t2bf.<sec>.gz     tree_sha;blob_sha;filename   (BLOB entries: file/exec/symlink) -- main; pigz
#   t2ctc.<sec>.gz    parent;child                 (NON-canonical subtree edges t2ct's exact-040000
#                                                   test missed -> complements t2ct); small
#   unk.<sec>.gz      parent;sha;mode;filename      (entries with an unrecognized type mask ->
#                                                   resolve object type via the store); usually empty
# Consumer: isaac re-shards t2bf by blob sha -> b2ptf; folds t2ctc into t2ct.
set -u
P=${1:-16}
OUT=${OUT:-/fast/All.blobsGen/t2bf}; mkdir -p "$OUT"
BASE=${BASE:-/data/All.blobs}
GEN=${GEN:-/fast/All.blobsGen/tree_gen1}
BIN=${BIN:-/da5_fast/bin/t2bfBuild}
export OUT BASE GEN BIN
echo "=== t2bfHost P=$P $(date) OUT=$OUT ==="
one(){
  s=$1
  [ -f "$OUT/t2bf.$s.done" ] && { echo "sec $s already done"; return 0; }
  cf="$OUT/t2ctc.$s"; uf="$OUT/unk.$s"; : > "$cf"; : > "$uf"      # fresh per (re)run; base+gen append
  { "$BIN" "$BASE/tree_$s.idx" "$BASE/tree_$s.bin" "$cf" "$uf"
    [ -s "$GEN/tree_$s.idx" ] && "$BIN" "$GEN/tree_$s.idx" "$GEN/tree_$s.bin" "$cf" "$uf"; } 2>>"$OUT/t2bf.$s.err" \
    | pigz -p2 > "$OUT/t2bf.$s.gz.tmp" && mv "$OUT/t2bf.$s.gz.tmp" "$OUT/t2bf.$s.gz" || { echo "sec $s FAILED"; return 1; }
  gzip -f "$cf" 2>/dev/null; gzip -f "$uf" 2>/dev/null
  touch "$OUT/t2bf.$s.done"
  echo "sec $s DONE $(date): $(zcat "$OUT/t2bf.$s.gz"|wc -l) blob rows | complement=$(zcat "$cf.gz" 2>/dev/null|wc -l) unknown=$(zcat "$uf.gz" 2>/dev/null|wc -l)"
}
export -f one
seq 0 127 | xargs -P"$P" -I{} bash -c 'one "$@"' _ {}
echo "=== t2bf BUILD COMPLETE $(date): $(ls "$OUT"/t2bf.*.done 2>/dev/null|wc -l)/128 ; t2ct-complement rows=$(zcat "$OUT"/t2ctc.*.gz 2>/dev/null|wc -l) unknown rows=$(zcat "$OUT"/unk.*.gz 2>/dev/null|wc -l) ==="
