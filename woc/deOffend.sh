#!/bin/bash
# Shrink oversized blob dumps by excluding repos whose blobs dominate. Safe to
# call repeatedly (e.g. every 30 min) WHILE the grab is still running -- some
# repos take days, so we don't wait for the whole shard.
#
# Two offender tests:
#   PER-SHARD : a shard whose blob.bin > SHARD_MIN AND a repo contributing
#               > REPO_MIN of (compressed) blob bytes in that shard.
#   AGGREGATE : a repo whose blob bytes summed over ALL shards of the dataset
#               exceed AGG_REPO_MIN -- catches repos that stay under REPO_MIN in
#               every shard yet waste a lot in total (blobs spread across shards).
#   TREE      : a repo whose TREES dominate by count (>TREE_COUNT_MAX) or bytes
#               (>TREE_AGG_MIN) across shards -- the blob tests never weigh trees,
#               so tree-bloat data repos (re-committed corpora, version-controlled
#               datasets: many trees+commits, few blobs) used to slip through.
# For each offending shard the offenders are removed IN PLACE (filterDeoff.pl):
# the existing blob+tree (+drop-commit subset's commits) idx/bin are rewritten by
# byte-copying only the kept objects -- NO re-grab, NO clones (there is no sense
# re-extracting from clones to drop objects we already have). A shard with a live
# grab is deferred (filtering would race the writer) until the grab finishes.
# Each offender is appended once to ~/trees/offenders as
#   repo;size;excluded <date>;summary
# A per-shard marker (<base>.<l>.excluded) accumulates excluded repos so a
# relaunched grab is not re-killed.
#
# DROP-COMMIT (keep-tags-only): repos listed in $DROPCOMMIT_FILE additionally have
# their COMMITS dropped (only their tags survive). Use for commit-bloat data repos
# (e.g. a corpus re-committed 100k+ times) where the bloat is commits, which neither
# the size triggers nor tree:0/blob:none clone filters can shrink. Default file empty
# => no behavior change.
#
#   deOffend.sh <m> <ver> [out]      e.g.  deOffend.sh 030 V2605 out
m=$1; ver=$2; out=${3:-out}; DT=202605; base=New$DT$ver
. "${WOC_CONFIG:-$HOME/bin/jetstream2.config}" 2>/dev/null
# TokyoCabinet (libtokyocabinet.so.9) lives in /usr/local/lib; a relaunched grab
# from cron/watchdog may not inherit LD_LIBRARY_PATH, so grabGitI.perl would abort
# at BEGIN ("cannot open shared object file"). Set it here so all relaunches load.
export LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
: "${VOL:=/media/volume}"; : "${TREES:=$VOL/trees}"; : "${OFFENDERS:=$TREES/offenders}"
: "${RSYNC_DEST:=da8:/mnt/ordos/data/data/update}"   # must match runExo.sh
DST=$VOL/$out/$ver.$m
REPOS=$TREES/$ver.$m
OFF=$OFFENDERS
SHARD_MIN=100000000000      # 100 GB - per-shard blob.bin trigger
REPO_MIN=30000000000        #  30 GB - per-shard repo trigger
: "${AGG_REPO_MIN:=30000000000}"   # 30 GB - cross-shard (aggregate) repo trigger
: "${KEEP_FILE:=$TREES/keep}"      # allowlist: repos NEVER excluded (one per line)
: "${COUNT_MAX:=1000000}"          # max blobs a repo may contribute before count-check
: "${REVIEW_FILE:=$TREES/review}"  # high-blob-count, not-clearly-data repos flagged here
: "${TREE_COUNT_MAX:=300000}"      # max TREES a repo may contribute (cross-shard) before flagged
: "${TREE_AGG_MIN:=20000000000}"   # 20 GB - cross-shard repo TREE-bytes trigger (tree-bloat data repos)
: "${DROPCOMMIT_FILE:=$TREES/dropcommit}"  # repos whose COMMITS are ALSO dropped (keep ONLY tags)
touch "$KEEP_FILE" "$DROPCOMMIT_FILE" 2>/dev/null
declare -A KEEP=() DROPC=()
while read -r _r; do [[ -n $_r && $_r != \#* ]] && KEEP["$_r"]=1; done < "$KEEP_FILE"
while read -r _r; do [[ -n $_r && $_r != \#* ]] && DROPC["$_r"]=1; done < "$DROPCOMMIT_FILE"

# per-dataset lock so the inline runExo loop and the cron watchdog never act on
# the same dataset at once (non-blocking: if busy, another instance has it)
exec 9>"/tmp/deOffend.$ver.$m.lock" 2>/dev/null
flock -n 9 || exit 0

[[ -d $REPOS ]] || exit 0
cd "$REPOS" || exit 0
today=$(date +%F)

# sweep stale .rb re-extraction temp files from a prior interrupted run: the
# blob-only path writes <shard>.rb.blob.{idx,bin} then mv's them into place, so
# any left behind mean that run died before the swap. The per-dataset flock
# above guarantees no other deOffend is mid-write here, so these are safe to drop.
rm -f "$DST"/$base.$m.*.rb.blob.idx "$DST"/$base.$m.*.rb.blob.bin "$DST"/$base.$m.*.rb.tree.idx "$DST"/$base.$m.*.rb.tree.bin "$DST"/$base.$m.*.rb.commit.idx "$DST"/$base.$m.*.rb.commit.bin "$DST"/$base.$m.*.excludedC 2>/dev/null
killtree(){ local p=$1 c; for c in $(pgrep -P "$p" 2>/dev/null); do killtree "$c"; done; kill -TERM "$p" 2>/dev/null; }

# ---- aggregate offenders (cross-shard), cached by an idx signature ----------
aggcache=$DST/$base.$m.aggoff; aggsig=$DST/$base.$m.aggsig; cands=$DST/$base.$m.aggcand
sig=$(stat -c '%n:%s:%Y' $DST/$base.$m.*.blob.idx $DST/$base.$m.*.tree.idx "$KEEP_FILE" 2>/dev/null | md5sum | cut -d' ' -f1)
if [[ ! -s $aggsig || $(cat "$aggsig" 2>/dev/null) != "$sig" ]]; then
  # candidates exceeding the byte cap OR the blob-count cap (keep-list skipped),
  # emitting repo<TAB>shards<TAB>bytes<TAB>count
  awk -F';' '
    FNR==NR { keep[$0]=1; next }
    FNR==1 { n=split(FILENAME,a,"."); shard=""; for(i=1;i<=n;i++) if(a[i]=="blob"){shard=a[i-1];break} }
    shard!="" && !($5 in keep) { s[$5]+=$2; c[$5]++; k=$5"@"shard; if(!(k in seen)){seen[k]=1; sh[$5]=sh[$5]" "shard} }
    END { for(r in s) if(s[r]>BMIN || c[r]>CMAX) print r"\t"sh[r]"\t"s[r]"\t"c[r] }
  ' BMIN="$AGG_REPO_MIN" CMAX="$COUNT_MAX" "$KEEP_FILE" $DST/$base.$m.*.blob.idx 2>/dev/null > "$cands"
  # classify: bytes>cap -> exclude; else count>cap -> content decides (DATA exclude, else review)
  : > "$aggcache"
  while IFS=$'\t' read -r rp shards bytes cnt; do
    [[ -z $rp ]] && continue
    if (( bytes > AGG_REPO_MIN )); then
      printf '%s\t%s\t%s\n' "$rp" "$shards" "$bytes" >> "$aggcache"
    else
      info=$("$HOME/bin/repoExt.sh" "$REPOS/$rp")
      if [[ $info == *verdict=DATA* ]]; then
        printf '%s\t%s\t%s\n' "$rp" "$shards" "$bytes" >> "$aggcache"
        grep -q "^${rp};" "$REVIEW_FILE" 2>/dev/null || echo "$rp;blobs=$cnt;bytes=$bytes;$info;auto-excluded(count+data)" >> "$REVIEW_FILE"
      else
        grep -q "^${rp};" "$REVIEW_FILE" 2>/dev/null || echo "$rp;blobs=$cnt;bytes=$bytes;$info;REVIEW: high blob count, not clearly data -> add to $KEEP_FILE to keep or exclude manually" >> "$REVIEW_FILE"
      fi
    fi
  done < "$cands"
  # ---- TREE offenders: a repo whose TREES dominate by count or bytes. Appended to
  # the SAME aggcache so the per-shard loop excludes the repo's blobs AND trees via
  # the existing path. (keep-list skipped.) These are flagged regardless of blob size.
  awk -F';' '
    FNR==NR { keep[$0]=1; next }
    FNR==1 { n=split(FILENAME,a,"."); shard=""; for(i=1;i<=n;i++) if(a[i]=="tree"){shard=a[i-1];break} }
    shard!="" && !($5 in keep) { s[$5]+=$2; c[$5]++; k=$5"@"shard; if(!(k in seen)){seen[k]=1; sh[$5]=sh[$5]" "shard} }
    END { for(r in s) if(s[r]>TMIN || c[r]>TCMAX) print r"\t"sh[r]"\t"s[r] }
  ' TMIN="$TREE_AGG_MIN" TCMAX="$TREE_COUNT_MAX" "$KEEP_FILE" $DST/$base.$m.*.tree.idx 2>/dev/null >> "$aggcache"
  echo "$sig" > "$aggsig"
fi

# shards whose dumps this run re-extracted/truncated -- if the dataset was
# already rsynced, da8 still holds the pre-cull (offender-laden) copy, so we
# must re-rsync just these shards before upgrading STAGE to verified.
declare -A DIRTY=()

for l in {00..15}; do
  binf=$DST/$base.$m.$l.blob.bin
  [[ -f $binf ]] || continue
  sz=$(stat -c%s "$binf" 2>/dev/null || echo 0)

  declare -A cand=()
  # (a) per-shard offenders -- only when the shard itself is oversized
  if (( sz > SHARD_MIN )); then
    while IFS=';' read -r by rp; do [[ -n $rp && -z ${KEEP[$rp]} ]] && cand["$rp"]=$by; done \
      < <("$HOME/bin/largest.sh" "$DST/$base.$m.$l.blob" | awk -F';' -v t=$REPO_MIN '$1>t{print $1";"$2}')
  fi
  # (b) aggregate/tree offenders that appear in this shard -- regardless of shard size
  while IFS=$'\t' read -r rp shards tot; do
    [[ -n $rp && " $shards " == *" $l "* ]] && cand["$rp"]=$tot
  done < "$aggcache"
  # (c) registry offenders (manually-added or logged) whose blobs OR trees are
  # still present in this shard -- the offenders list actively excludes blob AND
  # tree content of any flagged repo, regardless of size/count (e.g. image/data
  # dumps whose bloat is in trees, not blobs). One pass over blob.idx + tree.idx.
  if [[ -s $OFF ]]; then
    for _ix in blob tree; do
      _f=$DST/$base.$m.$l.$_ix.idx; [[ -f $_f ]] || continue
      while read -r rp; do [[ -n $rp && -z ${KEEP[$rp]} ]] && cand["$rp"]=registry; done \
        < <(awk -F';' 'NR==FNR{o[$1]=1;next} ($5 in o){s[$5]=1} END{for(k in s)print k}' \
              <(cut -d';' -f1 "$OFF") "$_f")
    done
    # drop-commit repos: also flag when only their COMMITS linger (blobs/trees may
    # already be culled) so a re-run still removes the commits (tags kept).
    _f=$DST/$base.$m.$l.commit.idx
    if [[ -f $_f ]]; then
      while read -r rp; do [[ -n $rp && -n ${DROPC[$rp]} && -z ${KEEP[$rp]} ]] && cand["$rp"]=registry; done \
        < <(awk -F';' 'NR==FNR{o[$1]=1;next} ($5 in o){s[$5]=1} END{for(k in s)print k}' \
              <(cut -d';' -f1 "$OFF") "$_f")
    fi
  fi
  (( ${#cand[@]} )) || continue

  # accumulate excluded repos in a marker; act on a NEW one, OR on a marked one
  # whose blobs are STILL present (a prior removal was interrupted/raced/failed
  # -- otherwise that offender stays stuck forever and blocks verify).
  mark=$DST/$base.$m.$l.excluded; touch "$mark"; newoff=0
  for rp in "${!cand[@]}"; do
    if grep -qxF "$rp" "$mark"; then
      _ixset="blob tree"; [[ -n ${DROPC[$rp]} ]] && _ixset="blob tree commit"
      for _ix in $_ixset; do _f=$DST/$base.$m.$l.$_ix.idx
        [[ -f $_f ]] && awk -F';' -v o="$rp" '$5==o{f=1;exit} END{exit !f}' "$_f" && newoff=1; done
    else
      echo "$rp" >> "$mark"; newoff=1
    fi
  done
  (( newoff )) || continue
  pat=$(paste -sd'|' "$mark")
  # drop-commit subset present in this shard: also strip their COMMITS (keep tags).
  # markc = exclusion set used for the commit truncate check; patc = grep alternation.
  markc=$DST/$base.$m.$l.excludedC; : > "$markc"; patc=""
  while read -r _r; do [[ -n $_r && -n ${DROPC[$_r]} ]] && { echo "$_r" >> "$markc"; patc="${patc:+$patc|}$_r"; }; done < "$mark"

  pid=$(pgrep -f "grabGitI(Type)?\.perl .*/$base\.$m\.$l\$")
  echo "[deOffend $(date '+%F %T')] $base.$m.$l ($((sz/1000000000))GB) exclude=$(paste -sd, "$mark") dropcommit=${patc:-none} live=${pid:-none}" >&2

  # IN-PLACE offender removal -- NO grab, NO clones. Rewrite the affected idx/bin by
  # byte-copying only the kept objects (filterDeoff.pl), dropping offenders' blob+tree
  # and the drop-commit subset's commits. There is no sense re-grabbing from clones to
  # remove objects we already have; the existing dump is authoritative. The original
  # grab applied the offender filter at grab time, so a clean dump never needs this --
  # this only fixes dumps that predate an offender's registration.
  if [[ -n $pid ]]; then
    # A live grab is still writing this shard; filtering it now would race the writer.
    # Defer: the grab finishes (offenders included), a later cycle removes them in place.
    echo "[deOffend] $base.$m.$l has live grab ($pid) -- deferring in-place removal" >&2
  else
    swapt="blob tree"; [[ -n $patc ]] && swapt="blob tree commit"
    for _t in $swapt; do
      [[ -s $DST/$base.$m.$l.$_t.idx ]] || continue
      # offenders=$mark (this shard's exclusion set), dropcommit=$markc; no blobonly here
      perl "$HOME/bin/filterDeoff.pl" "$_t" "$DST/$base.$m.$l" "$mark" "${KEEP_FILE:-}" "" "$markc" \
        2>> "$DST/$base.$m.$l.deoff.err"
      _rb=$DST/$base.$m.$l.deoff.$_t
      # filterDeoff always writes the output (empty if the type was 100% offenders --
      # that empty swap correctly removes a count-offender that fills a whole shard).
      [[ -f $_rb.idx ]] && { mv -f "$_rb.idx" "$DST/$base.$m.$l.$_t.idx"; mv -f "$_rb.bin" "$DST/$base.$m.$l.$_t.bin"; }
    done
    rm -f "$markc"
    DIRTY[$l]=1   # in-place removal completed synchronously -- shard's dumps changed
  fi

  # log offenders (dedup by repo) with README/CLAUDE.md summary; size shown is
  # the aggregate (cross-shard) total when known, else the per-shard bytes
  for rp in "${!cand[@]}"; do
    grep -q "^${rp};" "$OFF" 2>/dev/null && continue
    gb=$(awk "BEGIN{printf \"%.1f\", ${cand[$rp]}/1e9}" 2>/dev/null)
    summ=$("$HOME/bin/readmeSummary.sh" "$REPOS/$rp")
    printf '%s;%sGB;excluded %s;%s\n' "$rp" "$gb" "$today" "$summ" >> "$OFF"
  done
done

# verification: once runExo has rsynced (STAGE=rsynced) and there is nothing
# left to de-offend (no shard >SHARD_MIN, no grab running), upgrade the repo
# folder's STAGE marker to "verified" -- safe to delete repo clones and dumps.
STAGEF=$REPOS/STAGE
if [[ -f $STAGEF ]] && grep -q '^rsynced' "$STAGEF" 2>/dev/null; then
  big=0
  # re-propagate shards this run culled: deOffend changed the dump locally but
  # the prior rsync left the offender-laden copy on da8. A post-rsync cull (late
  # registry/aggregate offender, or the all-offender truncate) would otherwise
  # verify with stale bloated data still on da8 (seen on 055 and 088).
  if (( ${#DIRTY[@]} )); then
    rfiles=()
    for l in "${!DIRTY[@]}"; do
      for f in $DST/$base.$m.$l.{blob,commit,tree,tag}.{bin,idx}; do [[ -f $f ]] && rfiles+=("$f"); done
    done
    if (( ${#rfiles[@]} )); then
      echo "[deOffend $(date '+%F %T')] $base.$m: re-rsync culled shards ${!DIRTY[*]} to da8" >&2
      rsync -a "${rfiles[@]}" "$RSYNC_DEST/$ver/" \
        || { echo "[deOffend] $base.$m: re-rsync FAILED -- NOT verifying" >&2; big=1; }
    fi
  fi
  for l in {00..15}; do
    bb=$DST/$base.$m.$l.blob.bin
    [[ -f $bb ]] && (( $(stat -c%s "$bb" 2>/dev/null || echo 0) > SHARD_MIN )) && { big=1; break; }
  done
  # also require no outstanding aggregate offender
  [[ -s $aggcache ]] && big=1
  # NEVER verify a failed grab (silent data loss): (1) grab* loader errors, or
  # (2) a non-empty olist that produced ZERO dumped objects (grab crashed).
  grep -lqE 'error while loading shared libraries' $DST/$base.$m.*.err 2>/dev/null && big=1
  if ls $DST/$base.$m.olist.*.gz >/dev/null 2>&1 \
     && [[ -z $(cat $DST/$base.$m.*.{blob,commit,tree,tag}.idx 2>/dev/null | head -c1) ]]; then
    echo "[deOffend] $base.$m: olist present but ALL dumps empty -- grab failed; NOT verifying" >&2; big=1
  fi
  if (( ! big )) && ! pgrep -f "grabGitI(Type)?\.perl .*/$base\.$m\." >/dev/null 2>&1; then
    echo "verified $(date '+%F %T') - safe to delete repos/dumps" > "$STAGEF"
  fi
fi
