#!/bin/bash
# runExoMirror.sh <collection-dir> <base> [out] [rsub]
#   e.g. runExoMirror.sh /media/volume/trees/Chromium-Gerrit New20260606Chromium out Chromium
#
# runExo.sh analog for a KEPT mirror collection (Chromium-Gerrit, Mozilla, ...).
# Instead of the slow gitListSimp (`rev-list --objects --all`, which walks every
# tree to emit paths), it enumerates the object DB directly with
#   git cat-file --batch-all-objects --unordered --batch-check='%(objectname) %(objecttype)'
# (~6x faster; gecko-dev 12.8M objs: 2:57 -> 0:31). No paths are produced -- we
# dump blob *content* by SHA and WoC reconstructs filenames from the tree objects
# (also dumped), so the olist is repo;type;sha; (empty path field for format
# compatibility with cleanBlb/hasObj/grabGitI). Works for full mirrors AND
# partial tip-fetch repos (lists exactly the present objects).
#
# Flow (mirrors runExo): enumerate -> shard 16 -> da5 cleanBlb|hasObj (drop what
# WoC already has = "only new") -> grabGitI dumps survivors -> rsync to da8.
set -u
COLL=${1:?usage: runExoMirror.sh <collection-dir> <base> [out] [rsub]}
base=${2:?need dump base, e.g. New20260606Chromium}
out=${3:-out}; rsub=${4:-$(basename "$COLL")}
. "${WOC_CONFIG:-$HOME/bin/jetstream2.config}" 2>/dev/null
: "${VOL:=/media/volume}"; : "${RSYNC_DEST:=da8:/mnt/ordos/data/data/update}"; : "${HASOBJ_HOST:=da5}"
export LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
DST=$VOL/$out/$rsub; mkdir -p "$DST"
[[ -d $COLL ]] || { echo "no collection dir $COLL" >&2; exit 1; }
cd "$COLL" || exit 1

# 1. discover bare repos at any depth (repo = dir holding objects/)
find . -type d -name objects -prune 2>/dev/null | sed 's#/objects$##; s#^\./##' | sort > "$DST/repos.list"
nrepos=$(wc -l < "$DST/repos.list"); echo "repos: $nrepos  -> dumps in $DST"

# 2. enumerate objects (fast, no tree walk) + WoC dedup, 16-way in parallel
#    per chunk: cat-file --batch-all-objects -> repo;type;sha;  -> da5 cleanBlb|hasObj -> todo.N
split -n l/16 -d "$DST/repos.list" "$DST/repochunk."
enum_chunk(){
  local ch=$1 n=$2
  while read -r repo; do
    [ -d "$repo/objects" ] || continue
    git --git-dir="$repo" cat-file --batch-all-objects --unordered \
        --batch-check='%(objectname) %(objecttype)' 2>/dev/null \
      | awk -v R="$repo" 'NF==2{print R";"$2";"$1";"}'
  done < "$ch" | gzip > "$DST/$base.$n.olist.gz"
  zcat "$DST/$base.$n.olist.gz" \
    | ssh "$HASOBJ_HOST" -At '$HOME/lookup/cleanBlb.perl | $HOME/bin/hasObj.perl' \
    | gzip > "$DST/todo.$n"
}
export -f enum_chunk; export DST base HASOBJ_HOST
for n in 00 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15; do
  enum_chunk "$DST/repochunk.$n" "$n" &
done
wait
echo "enumerate+dedup done; new objects (not in WoC): $(zcat $DST/todo.[0-9]* 2>/dev/null | wc -l)"

# 3. merge survivors, re-split into 16, grabGitI dumps the content
zcat "$DST"/todo.[0-9]* 2>/dev/null | gzip > "$DST/todo"
nlines=$(zcat "$DST/todo" | wc -l); part=$(( nlines/16 + 1 ))
zcat "$DST/todo" | split -l "$part" -a2 -d --filter='gzip > $FILE.gz' - "$DST/$base.olist."
for n in $(ls "$DST/$base".olist.*.gz 2>/dev/null | sed 's/.*olist\.//;s/\.gz//'); do
  gunzip -c "$DST/$base.olist.$n.gz" | perl -I "$HOME/lib64/perl5" "$HOME/bin/grabGitI.perl" "$DST/$base.$n" 2> "$DST/$base.$n.err" &
done
wait
echo "grab done. dump sizes:"; du -ch "$DST"/$base.*.{blob,commit,tree,tag}.bin 2>/dev/null | tail -1

# 4. rsync dumps to da8
rsync -a "$DST"/$base.olist.*.gz "$DST"/$base.*.{blob,commit,tree,tag}.{bin,idx} "$RSYNC_DEST/$rsub/" \
  && echo "rsynced $(date '+%F %T') -> $RSYNC_DEST/$rsub/" || echo "rsync FAILED"
