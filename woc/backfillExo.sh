#!/bin/bash
# backfillExo.sh <m> <ver> <DT> [out]            e.g. backfillExo.sh 071 V2605 202605 out
#   SELECT=/path/to/repos.lst backfillExo.sh ...  (only those mangled repo names)
#
# PHASE 2 of two-phase deferred-blob extraction: download the blobs that phase 1
# (fetchExoP1.sh, filter blob:none) deferred. The repos are GONE (deleted for
# disk), so this works purely from the persisted artifacts:
#   $DST/backfill.$m.gz : 'repo;blob;oid;'  (blob OIDs referenced by trees)
#   $DST/urls.$m.gz     : 'mangled<TAB>url' (forge-correct upstream URL per repo)
# Per repo it fetches exactly its blob OIDs (no haves -> the server cannot
# exclude reachable blobs), dumps them into separate '.bf.' shards, and rsyncs.
#
# Selection: set SELECT to a file of mangled repo names to backfill only those
# (the "metadata-select for deep extraction" knob -- pick repos using the commit
# /tree data already dumped in phase 1). Default: every repo with pending blobs.
set -u
m=${1:?usage: backfillExo.sh <m> <ver> <DT> [out]}; ver=${2:?}; DT=${3:?}; out=${4:-out}
. "${WOC_CONFIG:-$HOME/bin/jetstream2.config}" 2>/dev/null
: "${VOL:=/media/volume}"; : "${TREES:=$VOL/trees}"
: "${RSYNC_DEST:=da8:/mnt/ordos/data/data/update}"; : "${HASOBJ_HOST:=da5}"
: "${PAR:=8}"          # parallel fetch workers
export LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
base=New$DT$ver
DST=$VOL/$out/$ver.$m
BF=$DST/backfill.$m.gz; URLS=$DST/urls.$m.gz
SELECT=${SELECT:-}
[ -f "$BF" ]   || { echo "[p2 $ver.$m] missing $BF (run fetchExoP1.sh first / fetch it back from da8)"; exit 1; }
[ -f "$URLS" ] || { echo "[p2 $ver.$m] missing $URLS"; exit 1; }

WORK=$DST/bf.$m; rm -rf "$WORK"; mkdir -p "$WORK/want" "$WORK/repos"

# 1. re-dedup vs CURRENT WoC (blobs may have landed since phase 1) + optional
#    selection -> one want-file per repo (sorted so only one fd is open at a time)
echo "[p2 $ver.$m] re-dedup + group want-lists $(date '+%F %T')"
pigz -dc "$BF" \
  | { [ -n "$SELECT" ] && grep -Ff "$SELECT" || cat; } \
  | ssh "$HASOBJ_HOST" -At '$HOME/lookup/cleanBlb.perl | $HOME/bin/hasObj.perl' \
  | LC_ALL=C sort -t';' -k1,1 -S2G \
  | awk -F';' -v D="$WORK/want" -v M="$WORK/.map" '
      $1!=prev { if(prev!="") close(f); prev=$1; key=$1; gsub(/[^A-Za-z0-9._-]/,"_",key);
                 f=D"/"key; print $1"\t"key >> M }
      { print $3 > f }'
[ -s "$WORK/.map" ] || { echo "[p2 $ver.$m] nothing to backfill"; echo "blobs-done $(date '+%F %T')" > "$TREES/$ver.$m/PHASE"; exit 0; }
echo "[p2 $ver.$m] repos to backfill: $(wc -l < "$WORK/.map")"

# join map(repo,key) with urls(repo,url) -> jobs: repo<TAB>key<TAB>url
LC_ALL=C sort -t$'\t' -k1,1 "$WORK/.map" > "$WORK/.map.s"
pigz -dc "$URLS" | LC_ALL=C sort -t$'\t' -k1,1 > "$WORK/.urls.s"
LC_ALL=C join -t$'\t' -1 1 -2 1 "$WORK/.map.s" "$WORK/.urls.s" > "$WORK/jobs"

# 2. fetch the blob OIDs per repo (no haves), bounded parallelism
echo "[p2 $ver.$m] fetching deferred blobs ($PAR-way) $(date '+%F %T')"
n=0
while IFS=$'\t' read -r repo key url; do
  ( rd="$WORK/repos/$repo"; mkdir -p "$(dirname "$rd")"
    python3 "$HOME/bin/fetchNew.py" "$url" --want-file "$WORK/want/$key" --out "$rd" \
      >>"$WORK/fetch.log" 2>&1 || echo "BFFAIL $repo" >> "$WORK/fetch.err" ) &
  n=$((n+1)); (( n % PAR == 0 )) && wait
done < "$WORK/jobs"
wait

# 3. enumerate the fetched blobs -> olist (repo;blob;oid;) -> grabGitIType dumps
echo "[p2 $ver.$m] dumping blobs $(date '+%F %T')"
( cd "$WORK/repos" && while IFS=$'\t' read -r repo key url; do
    [ -d "$repo/objects" ] || continue
    git --git-dir="$repo" cat-file --batch-all-objects --unordered \
        --batch-check='%(objectname) %(objecttype)' 2>/dev/null \
      | awk -v R="$repo" '$2=="blob"{print R";blob;"$1";"}'
  done < "$WORK/jobs" ) | pigz > "$DST/$base.$m.bf.olist.gz"

nlines=$(pigz -dc "$DST/$base.$m.bf.olist.gz" | wc -l)
echo "[p2 $ver.$m] new blobs fetched: $nlines"
if (( nlines > 0 )); then
  part=$(( nlines/16 + 1 ))
  pigz -dc "$DST/$base.$m.bf.olist.gz" | split -l "$part" -a2 -d --filter='pigz > $FILE.gz' - "$DST/$base.$m.bf.olist."
  for f in "$DST/$base.$m.bf.olist."[0-9][0-9].gz; do
    l=$(echo "$f" | sed 's/.*\.olist\.//;s/\.gz//')
    ( cd "$WORK/repos" && pigz -dc "$f" \
        | perl -I "$HOME/lib64/perl5" "$HOME/bin/grabGitIType.perl" "$DST/$base.$m.bf.$l" blob \
        2> "$DST/$base.$m.bf.$l.err" ) &
  done
  wait
  # 4. ship the blob dumps to da8 (complements the phase-1 commit/tree dumps)
  rsync -a "$DST"/$base.$m.bf.olist.*.gz "$DST"/$base.$m.bf.*.blob.{bin,idx} "$RSYNC_DEST/$ver/" \
    && echo "[p2 $ver.$m] rsynced blob dumps -> da8"
fi

rm -rf "$WORK"                 # free disk: mini-repos were transient
echo "blobs-done $(date '+%F %T')" > "$TREES/$ver.$m/PHASE"
echo "[p2 $ver.$m] DONE $(date '+%F %T')"
