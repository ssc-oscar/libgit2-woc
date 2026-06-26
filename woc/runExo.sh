ver=$2
m=$1
out=${3:-out}
DT=202605
base=New$DT$ver

. "${WOC_CONFIG:-$HOME/bin/jetstream2.config}" 2>/dev/null
: "${VOL:=/media/volume}"; : "${TREES:=$VOL/trees}"
: "${RSYNC_DEST:=da8:/mnt/ordos/data/data/update}"; : "${HASOBJ_HOST:=da5}"
: "${REFERENCE_FILE:=$TREES/reference}"   # reference-class repos: archived intact (archiveReference.sh), NOT extracted into WoC

[[ -d $ver.$m ]] || exit
DST=$VOL/$out/$ver.$m
mkdir -p $DST
cd $ver.$m

# gate: do not start the grab until the clone/list step (doOtrVer.sh) finished.
# STAGE lifecycle (this repo folder): cloning -> listed -> grabbing -> rsynced -> verified
grep -qE '^(listed|grabbing|rsynced|verified)\b' STAGE 2>/dev/null || {
  echo "$ver.$m: STAGE='$(cat STAGE 2>/dev/null)' -- clone/list not finished; skipping grab" >&2
  exit 1; }
echo "grabbing $(date '+%F %T')" > STAGE

cp list$DT.${ver}1.$m  CopyList.${ver}1.$m
nlines=$(cat CopyList.${ver}1.$m |wc -l);
part=$(echo "$nlines/16 + 1"|bc);
cat CopyList.${ver}1.$m | split -l $part --numeric-suffixes - CopyList.${ver}1.$m.

# record the CLONE date per repo (mangled name -> bare-repo dir mtime, epoch):
# when the repo was cloned/fetched -- the as-of date of the captured objects
# (NOT the grab/extraction run, which only reads). Captured before repos are
# deleted post-verify, and rsynced to da8 with the dumps.
while read -r r; do [ -d "$r" ] && printf '%s;%s\n' "$r" "$(stat -c %Y "$r" 2>/dev/null)"; done \
  < CopyList.${ver}1.$m | pigz > $DST/$base.$m.p2cd.gz


for l in {00..15}
do 
# fast object enumeration: cat-file --batch-all-objects (no tree walk, ~6x faster
# than gitListSimp's rev-list --objects --all + classify). No paths (blob content
# is dumped by sha; WoC rebuilds filenames from the dumped trees) -> olist is
# repo;type;sha; . Also works for partial tip-fetch repos (lists present objects).
(cat CopyList.${ver}1.$m.$l | while read repo; do  [[ -d $repo/ ]] && git --git-dir="$repo" cat-file --batch-all-objects --unordered --batch-check='%(objectname) %(objecttype)' 2>> $DST/$base.$m.$l.olist.err | awk -v R="$repo" '$2~/^(blob|tree|commit|tag)$/{print R";"$2";"$1";"}'
done | pigz > $DST/$base.$m.$l.olist.gz; \
# dedup: cleanBlb (intra-shard) | hasObjBF (binary-fuse, da5 RAM; resolves
# definitely-new objects locally) ; only the maybe-present defer to the exact
# hasObj (.tch). ~4x faster, identical survivors, 0 false negatives. Filters
# (all types) live on da5 /fast/objFilters (rebuild via lookup/build_all_type.sh).
pigz -dc $DST/$base.$m.$l.olist.gz | ssh $HASOBJ_HOST -At 'd=$(mktemp); $HOME/lookup/cleanBlb.perl | $HOME/bin/hasObjBF /fast/objFilters "$d"; $HOME/bin/hasObj.perl < "$d"; rm -f "$d"' | pigz > $DST/todo.$m.$l) &
#rsync -av *.$l.olist.gz da5:/data/play/$ver/; \
#ssh da5 "/data/play/V4/toTodo1.sh $m $l" < /dev/null
#) &
done

wait
#rsync -av list202406* *.olist.gz da8:/mnt/ordos/data/data/update/V4/
#rsync -av *.olist.gz da5:/data/play/$ver/

# run on da5
#ssh da5 "/da8_data/update/V4/toTodo.sh $m"

#rsync -av da5:/data/play/$ver/todo.$m.* .
#for l in {00..15}; do sleep 1; [[ ! -f todo.$m.$l  || 0 -eq $(zcat todo.$m.$l|wc -l) ]] && ssh da5 "/data/play/$ver/toTodo1.sh $m $l" < /dev/null & done
#wait
#rsync -av da5:/data/play/$ver/todo.$m.* .

pigz -dc $DST/todo.$m.[0-2][0-9] | pigz > $DST/todo.$m


nlines=$(pigz -dc $DST/todo.$m |wc -l)
part=$(echo "$nlines/16 + 1"|bc)
pigz -dc $DST/todo.$m | split -l $part -a2 -d  --filter='pigz > $FILE.gz' - $DST/$base.$m.olist.


# offenders blob-exclude: drop blob lines of repos listed in the offenders
# registry (keep their commit/tree/tag), so flagged repos never contribute blob
# content -- same effect as deOffend's per-shard exclusion, applied globally.
cut -d';' -f1 "${OFFENDERS:-$TREES/offenders}" 2>/dev/null | sort -u > $DST/.offrepos
# reference-class repos: curated catalogues archived intact (archiveReference.sh) -> skip
# ALL their object types here so nothing is ingested into WoC.
grep -v '^#' "$REFERENCE_FILE" 2>/dev/null | cut -d';' -f1 | sort -u > $DST/.refrepos
for l in {00..15}
do pigz -dc $DST/$base.$m.olist.$l.gz \
   | awk -F';' -v RF="$DST/.refrepos" -v OF="$DST/.offrepos" '
       BEGIN{ while((getline x < RF)>0) ref[x]=1; while((getline x < OF)>0) off[x]=1 }
       ref[$1]{next}                                # reference repo -> skip ALL types (archived intact)
       off[$1] && ($2=="blob"||$2=="tree"){next}    # offender -> skip blob/tree (keep commit/tag)
       {print}' \
   | perl -I $HOME/lib64/perl5 $HOME/bin/grabGitI.perl $DST/$base.$m.$l 2> $DST/$base.$m.$l.err &
done

# Some repos take days to grab; de-offend oversized shards every ~30 min while
# the grabs (and any relaunched de-offended grabs) are still running. The pgrep
# loop also waits for those relaunches to finish before the rsync below.
# (deOffendWatch.sh in cron is a separate safety net; deOffend.sh locks per
# dataset so the two never race.)
elapsed=0
while pgrep -f "grabGitI(Type)?\.perl .*/$base\.$m\." >/dev/null 2>&1; do
  sleep 60; elapsed=$((elapsed+60))
  if (( elapsed >= 1800 )); then $HOME/bin/deOffend.sh $m $ver $out; elapsed=0; fi
done
wait 2>/dev/null
$HOME/bin/deOffend.sh $m $ver $out      # final sweep for shards finished between polls

rsync -av list$DT.* $DST/*.olist.gz $DST/$base.$m.p2cd.gz $DST/*.{blob,commit,tree,tag}.{bin,idx} $RSYNC_DEST/$ver/ \
  && echo "rsynced $(date '+%F %T')" > $TREES/$ver.$m/STAGE
# The repo-folder STAGE marker progresses: rsynced -> verified. This deOffend
# call confirms no oversized shards remain and upgrades STAGE to "verified ..."
# -- then it is safe to delete the repo clones and the dumps. (The cron
# watchdog also performs this upgrade as a safety net.)
$HOME/bin/deOffend.sh $m $ver $out
#cat list$DT.${ver}1.* | while read i; do [[ -d $i ]] && find $i -delete; done &

