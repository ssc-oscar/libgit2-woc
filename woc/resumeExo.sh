#!/bin/bash
# resumeExo.sh <m> <ver> <CLshard:outshard> [<CLshard:outshard> ...]
#
# Resume/complete a partial grab: grab ONLY the named CopyList shards through the
# same enumerate | dedup | grab path as runExo.sh, writing each into a chosen
# OUTPUT shard name. Use a FRESH output name when the original shard is partially
# on da8 (e.g. 13:16) so existing dumps are never overwritten -- any redundant
# re-dumped object is deduped at WoC ingest, so no corruption and no data loss.
#
# Reads the bare repos still on disk in $TREES/$ver.$m and the CopyList.<ver>1.<m>.<l>
# splits left by the original runExo. Does NOT run any ingest / AllUpdateObj.
#
#   resumeExo.sh 106 V2605 13:16 14:14 15:15
#       grab CopyList shards 13,14,15 of V2605.106 into output shards 16,14,15;
#       the partial da8 shard .13 is left intact (13 re-grabbed as 16).
#
# Output: $VOL/out/$ver.$m.finish/New<DT><ver>.<m>.<out>.{commit,tree,blob,tag}.{bin,idx}
# Then rsync those (+ a fresh p2cd clone-date file) to $RSYNC_DEST/$ver/.
set -u
m=${1:?usage: resumeExo.sh <m> <ver> <CLshard:outshard>...}; ver=${2:?}; shift 2
DT=202605; base=New${DT}${ver}
. "${WOC_CONFIG:-$HOME/bin/jetstream2.config}" 2>/dev/null
: "${VOL:=/media/volume}"; : "${TREES:=$VOL/trees}"
: "${RSYNC_DEST:=da8:/mnt/ordos/data/data/update}"; : "${HASOBJ_HOST:=da5}"
SRC=$TREES/$ver.$m
DST=$VOL/out/$ver.$m.finish; mkdir -p "$DST"
cd "$SRC" || { echo "no $SRC"; exit 1; }

# offender repos: drop their blob+tree lines (keep commit/tag), exactly as runExo
cut -d';' -f1 "${OFFENDERS:-$TREES/offenders}" 2>/dev/null | sort -u > "$DST/.offrepos"

pids=(); outs=()
for map in "$@"; do
  l=${map%%:*}; o=${map##*:}
  CL="CopyList.${ver}1.$m.$l"
  [ -s "$CL" ] || { echo "[$ver.$m] missing $CL -- skip"; continue; }
  outs+=("$o")
  (
    echo "[$ver.$m] CLshard $l -> out $o : enumerate $(wc -l <"$CL") repos $(date '+%T')"
    while read -r repo; do
      [ -d "$repo/" ] && git --git-dir="$repo" cat-file --batch-all-objects --unordered \
        --batch-check='%(objectname) %(objecttype)' 2>>"$DST/$base.$m.$o.olist.err" \
        | awk -v R="$repo" '$2~/^(blob|tree|commit|tag)$/{print R";"$2";"$1";"}'
    done < "$CL" | pigz > "$DST/$base.$m.$o.olist.gz"

    echo "[$ver.$m] out $o : dedup (cleanBlb|hasObjBF|hasObj) $(date '+%T')"
    pigz -dc "$DST/$base.$m.$o.olist.gz" \
      | ssh "$HASOBJ_HOST" -At 'd=$(mktemp); $HOME/lookup/cleanBlb.perl | $HOME/bin/hasObjBF /fast/objFilters "$d"; $HOME/bin/hasObj.perl < "$d"; rm -f "$d"' \
      | pigz > "$DST/todo.$m.$o.gz"

    echo "[$ver.$m] out $o : grab (offender blob/tree-excluded) $(date '+%T')"
    pigz -dc "$DST/todo.$m.$o.gz" \
      | awk -F';' 'NR==FNR{of[$1]=1;next} !(of[$1] && ($2=="blob"||$2=="tree"))' "$DST/.offrepos" - \
      | perl -I "$HOME/lib64/perl5" "$HOME/bin/grabGitI.perl" "$DST/$base.$m.$o" 2> "$DST/$base.$m.$o.err"
    echo "[$ver.$m] out $o : done $(date '+%T')  commit=$(wc -l <"$DST/$base.$m.$o.commit.idx" 2>/dev/null) tree=$(wc -l <"$DST/$base.$m.$o.tree.idx" 2>/dev/null) blob=$(wc -l <"$DST/$base.$m.$o.blob.idx" 2>/dev/null) tag=$(wc -l <"$DST/$base.$m.$o.tag.idx" 2>/dev/null)"
  ) &
  pids+=("$!")
done
for p in "${pids[@]}"; do wait "$p"; done

# fresh p2cd (per-repo clone date = bare-repo dir mtime) for the WHOLE dataset --
# the original grab predated p2cd, so this completes the dataset too.
echo "[$ver.$m] p2cd (clone dates) $(date '+%T')"
while read -r r; do [ -d "$r" ] && printf '%s;%s\n' "$r" "$(stat -c %Y "$r" 2>/dev/null)"; done \
  < "CopyList.${ver}1.$m" | pigz > "$DST/$base.$m.p2cd.gz"

echo "[$ver.$m] rsync new shards + p2cd -> $RSYNC_DEST/$ver/ $(date '+%T')"
files=("$DST/$base.$m.p2cd.gz")
for o in "${outs[@]}"; do files+=("$DST/$base.$m.$o".{commit,tree,blob,tag}.{bin,idx}); done
rsync -av "${files[@]}" "$RSYNC_DEST/$ver/" \
  && echo "[$ver.$m] rsynced OK; wrote shards: ${outs[*]} + p2cd to da8 (a shard reusing an original name REPLACES it; a fresh name is added alongside the existing shards)"
