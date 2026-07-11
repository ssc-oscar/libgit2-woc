#!/bin/bash
# rebuildGenIndex.sh -- rebuild the gen sidx + bf in place after a bin/idx compaction
# (e.g. genMinusBase). Same index step as convert_backlog.sh, matched to the compacted idx.
# Non-destructive to bins. Runs on da5. WOC = the woc checkout with sidx/build_bf/extract_sha.pl.
set -u
WOC=${WOC:-$HOME/swsc/libgit2-woc/woc}
GENROOT=${GENROOT:-/fast/All.blobsGen}
for T in commit tree; do
  GEN="$GENROOT/${T}_gen1"
  : > "$GEN/reindex.err"
  echo "[$(date +%T)] $T sidx+bf rebuild START (idx=$(ls "$GEN"/${T}_*.idx | wc -l))"
  ls "$GEN"/${T}_*.idx | WOC="$WOC" GEN="$GEN" xargs -P8 -I{} bash -c '
    f="$1"; b="${f%.idx}"
    "$WOC/sidx" build "$f" "$b.sidx" 2>>"$GEN/reindex.err"
    perl "$WOC/extract_sha.pl" "$f" | "$WOC/build_bf" "$b.bf" 2>>"$GEN/reindex.err" >/dev/null
  ' _ {}
  echo "[$(date +%T)] $T DONE sidx=$(ls "$GEN"/${T}_*.sidx | wc -l) bf=$(ls "$GEN"/${T}_*.bf | wc -l) err=$(wc -l < "$GEN/reindex.err")"
done
echo "REINDEX COMPLETE $(date)"
