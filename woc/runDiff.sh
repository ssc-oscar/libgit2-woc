#!/bin/bash
# runDiff.sh <sec>  -- V2604->V2605 DiffCT for one section. NO pre-processing of the .cs:
# the diff runs over the FULL .cs and every exception falls out of the .err stream, which is
# then post-processed into the category lists (identical-parent-tree, large, ...).
#   in : $D/V2604V2605.<sec>.cs        (gzip commit shas)
#   out: $D/V2604V2605.<sec>.gz        (diffs: commit;path;newblob;oldblob|renames)
#        $D/V2604V2605.<sec>.err       (exceptions stream)
#        $D/cIdentFull.V2605.<sec>.cs  (no-change commits: err '^identical trees:')
#        $D/cLargeFull.V2605.<sec>.cs  (skipped large-root commits: err '^large tree:')
# Empty-tree commits are NOT filtered (empty tree is a valid sha -> deletions vs a non-empty
# parent), and missing-tree commits just yield no output. env: D, MAXTREE (rootLen cutoff),
# BIN, LAYERED, PREO (base offset tch dir), BASEBIN.
set -u
D=${D:-/da8_data/update/V2605d}
MAXTREE=${MAXTREE:-250000}
BIN=${BIN:-/da5_fast/bin/cmputeDiffGen}
LAYERED=${LAYERED:-/da5_fast/All.blobsGen}
PREO=${PREO:-/fast/All.sha1o}
BASEBIN=${BASEBIN:-/data/All.blobs}
s=$1
zcat "$D/V2604V2605.$s.cs" \
  | LAYERED="$LAYERED" MAXTREE="$MAXTREE" "$BIN" "$PREO" "$BASEBIN" 2>"$D/V2604V2605.$s.err" \
  | gzip > "$D/V2604V2605.$s.gz"
grep '^identical trees:' "$D/V2604V2605.$s.err" | awk '{print $5}' | gzip > "$D/cIdentFull.V2605.$s.cs"
grep '^large tree:'      "$D/V2604V2605.$s.err" | awk '{print $5}' | gzip > "$D/cLargeFull.V2605.$s.cs"
echo "sec $s: diffs=$(zcat "$D/V2604V2605.$s.gz"|wc -l) ident=$(zcat "$D/cIdentFull.V2605.$s.cs"|wc -l) large=$(zcat "$D/cLargeFull.V2605.$s.cs"|wc -l)"
