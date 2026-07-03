ver=$2
m=$1
out=${3:-out}
DT=202605
base=New$DT$ver
# SEQUENTIAL variant of runExo.sh for the heavy 137+ ROOTS series: phase-1 (olist
# build) is identical, but phase-2 grabs ONE shard at a time and deoff+drains it
# (to da8, rm local) BEFORE starting the next -- bounding peak disk to ~one shard
# instead of all 16 in parallel (which filled b on 140). Disk-gated between shards.

. "${WOC_CONFIG:-$HOME/bin/jetstream2.config}" 2>/dev/null
: "${VOL:=/media/volume}"; : "${TREES:=$VOL/trees}"
: "${RSYNC_DEST:=da8:/mnt/ordos/data/data/update}"; : "${HASOBJ_HOST:=da5}"
: "${REFERENCE_FILE:=$TREES/reference}"
: "${MINFREE:=$((500*1000000000))}"   # wait for >=500G free on the dump disk before each shard

[[ -d $ver.$m ]] || exit
DST=$VOL/$out/$ver.$m
mkdir -p $DST
cd $ver.$m

grep -qE '^(listed|grabbing|rsynced|verified)\b' STAGE 2>/dev/null || {
  echo "$ver.$m: STAGE='$(cat STAGE 2>/dev/null)' -- clone/list not finished; skipping grab" >&2
  exit 1; }
echo "grabbing $(date '+%F %T')" > STAGE

cp list$DT.${ver}1.$m  CopyList.${ver}1.$m
nlines=$(cat CopyList.${ver}1.$m |wc -l);
part=$(echo "$nlines/16 + 1"|bc);
cat CopyList.${ver}1.$m | split -l $part --numeric-suffixes - CopyList.${ver}1.$m.

while read -r r; do [ -d "$r" ] && printf '%s;%s\n' "$r" "$(stat -c %Y "$r" 2>/dev/null)"; done \
  < CopyList.${ver}1.$m | pigz > $DST/$base.$m.p2cd.gz

# ---- phase 1: enumerate + dedup -> todo -> 16 olist shards (identical to runExo) ----
for l in {00..15}
do
(cat CopyList.${ver}1.$m.$l | while read repo; do  [[ -d $repo/ ]] && git --git-dir="$repo" cat-file --batch-all-objects --unordered --batch-check='%(objectname) %(objecttype)' 2>> $DST/$base.$m.$l.olist.err | awk -v R="$repo" '$2~/^(blob|tree|commit|tag)$/{print R";"$2";"$1";"}'
done | pigz > $DST/$base.$m.$l.olist.gz; \
pigz -dc $DST/$base.$m.$l.olist.gz | ssh $HASOBJ_HOST -At 'd=$(mktemp); $HOME/lookup/cleanBlb.perl | $HOME/bin/hasObjBF /fast/objFilters "$d"; $HOME/bin/hasObj.perl < "$d"; rm -f "$d"' | pigz > $DST/todo.$m.$l) &
done
wait

pigz -dc $DST/todo.$m.[0-2][0-9] | pigz > $DST/todo.$m
nlines=$(pigz -dc $DST/todo.$m |wc -l)
part=$(echo "$nlines/16 + 1"|bc)
pigz -dc $DST/todo.$m | split -l $part -a2 -d  --filter='pigz > $FILE.gz' - $DST/$base.$m.olist.

cut -d';' -f1 "${OFFENDERS:-$TREES/offenders}" 2>/dev/null | sort -u > $DST/.offrepos
grep -v '^#' "$REFERENCE_FILE" 2>/dev/null | cut -d';' -f1 | sort -u > $DST/.refrepos

# ---- phase 2: PARALLEL grab in a rolling pool of SHARD_PAR shards at a time, each
# shard deoff+drained (to da8, rm local) as it finishes -- bounds peak disk to ~SHARD_PAR
# shards (vs all 16 in runExo, which filled b on 140; vs 1 in the old seq, which serialized
# behind a single mega-dump offender and stalled 141 for hours). SHARD_PAR override:
#   SHARD_PAR=1 -> old one-at-a-time behaviour; default 4.
SHARD_PAR=${SHARD_PAR:-4}
echo "=== runExoSeq $ver.$m PARALLEL phase-2, SHARD_PAR=$SHARD_PAR $(date '+%F %T') ==="

grab_one() {   # grab shard $1, then deoff+drain it, then wait for the local blob.bin to clear
  local l="$1"
  echo "######## GRAB $m.$l $(date '+%F %T') ########"
  pigz -dc $DST/$base.$m.olist.$l.gz \
   | awk -F';' -v RF="$DST/.refrepos" -v OF="$DST/.offrepos" '
       BEGIN{ while((getline x < RF)>0) ref[x]=1; while((getline x < OF)>0) off[x]=1 }
       ref[$1]{next}
       off[$1] && ($2=="blob"||$2=="tree"){next}
       {print}' \
   | perl -I $HOME/lib64/perl5 $HOME/bin/grabGitI.perl $DST/$base.$m.$l 2> $DST/$base.$m.$l.err
  echo "  $m.$l grabbed $(date '+%T') ($(du -shc $DST/$base.$m.$l.*.bin 2>/dev/null|tail -1|cut -f1)); deoff+drain"
  $HOME/bin/deoffdrainP.sh $m $l
  local t=0; while [ -f "$DST/$base.$m.$l.blob.bin" ] && [ $t -lt 10800 ]; do sleep 60; t=$((t+60)); done
  echo "  $m.$l drained/cleared $(date '+%T'); $out free $(df -h $DST|awk 'END{print $4}')"
}

for l in {00..15}
do
  [ -f "$DST/$base.$m.olist.$l.gz" ] || { echo "[par $m.$l] no olist -- skip"; continue; }
  # throttle: keep at most SHARD_PAR grab_one subshells running at once
  while [ "$(jobs -rp | wc -l)" -ge "$SHARD_PAR" ]; do wait -n 2>/dev/null || sleep 5; done
  # disk gate: don't launch a new shard unless the dump disk has headroom
  while [ "$(df -B1 --output=avail "$DST"|tail -1)" -lt "$MINFREE" ]; do
    echo "[par $m.$l] waiting for >=$((MINFREE/1000000000))G on $out (now $(df -h $DST|awk 'END{print $4}')) $(date '+%T')"; sleep 180
  done
  # refresh offrepos from the LIVE registry (atomic file) right before launching this shard
  cut -d';' -f1 "${OFFENDERS:-$TREES/offenders}" 2>/dev/null | sort -u > $DST/.offrepos
  grab_one "$l" &
done
wait

echo "verified $(date '+%F %T') (par-$SHARD_PAR grab)" > $TREES/$ver.$m/STAGE
echo "=== runExoSeq $ver.$m DONE $(date '+%F %T') ==="
