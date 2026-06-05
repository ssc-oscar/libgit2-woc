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
# For each offending shard: if a grabGitI worker is still running, kill it and
# relaunch the FULL grab excluding the offenders' blobs; otherwise re-extract
# the shard's BLOBS only (commit/tree/tag left intact) and swap in the smaller
# dump. Each offender is appended once to ~/trees/offenders as
#   repo;size;excluded <date>;summary
# A per-shard marker (<base>.<l>.excluded) accumulates excluded repos so a
# relaunched grab is not re-killed.
#
#   deOffend.sh <m> <ver> [out]      e.g.  deOffend.sh 030 V2605 out
m=$1; ver=$2; out=${3:-out}; DT=202605; base=New$DT$ver
. "${WOC_CONFIG:-$HOME/bin/jetstream2.config}" 2>/dev/null
: "${VOL:=/media/volume}"; : "${TREES:=$VOL/trees}"; : "${OFFENDERS:=$TREES/offenders}"
DST=$VOL/$out/$ver.$m
REPOS=$TREES/$ver.$m
OFF=$OFFENDERS
SHARD_MIN=100000000000      # 100 GB - per-shard blob.bin trigger
REPO_MIN=30000000000        #  30 GB - per-shard repo trigger
: "${AGG_REPO_MIN:=30000000000}"   # 30 GB - cross-shard (aggregate) repo trigger
: "${KEEP_FILE:=$TREES/keep}"      # allowlist: repos NEVER excluded (one per line)
: "${COUNT_MAX:=1000000}"          # max blobs a repo may contribute before count-check
: "${REVIEW_FILE:=$TREES/review}"  # high-blob-count, not-clearly-data repos flagged here
touch "$KEEP_FILE" 2>/dev/null
declare -A KEEP=()
while read -r _r; do [[ -n $_r && $_r != \#* ]] && KEEP["$_r"]=1; done < "$KEEP_FILE"

# per-dataset lock so the inline runExo loop and the cron watchdog never act on
# the same dataset at once (non-blocking: if busy, another instance has it)
exec 9>"/tmp/deOffend.$ver.$m.lock" 2>/dev/null
flock -n 9 || exit 0

[[ -d $REPOS ]] || exit 0
cd "$REPOS" || exit 0
today=$(date +%F)
killtree(){ local p=$1 c; for c in $(pgrep -P "$p" 2>/dev/null); do killtree "$c"; done; kill -TERM "$p" 2>/dev/null; }

# ---- aggregate offenders (cross-shard), cached by an idx signature ----------
aggcache=$DST/$base.$m.aggoff; aggsig=$DST/$base.$m.aggsig; cands=$DST/$base.$m.aggcand
sig=$(stat -c '%n:%s:%Y' $DST/$base.$m.*.blob.idx "$KEEP_FILE" 2>/dev/null | md5sum | cut -d' ' -f1)
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
  echo "$sig" > "$aggsig"
fi

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
  # (b) aggregate offenders that appear in this shard -- regardless of shard size
  while IFS=$'\t' read -r rp shards tot; do
    [[ -n $rp && " $shards " == *" $l "* ]] && cand["$rp"]=$tot
  done < "$aggcache"
  (( ${#cand[@]} )) || continue

  # accumulate excluded repos in a marker; only act on a NEW one
  mark=$DST/$base.$m.$l.excluded; touch "$mark"; newoff=0
  for rp in "${!cand[@]}"; do
    grep -qxF "$rp" "$mark" || { echo "$rp" >> "$mark"; newoff=1; }
  done
  (( newoff )) || continue
  pat=$(paste -sd'|' "$mark")

  pid=$(pgrep -f "grabGitI(Type)?\.perl .*/$base\.$m\.$l\$")
  echo "[deOffend $(date '+%F %T')] $base.$m.$l ($((sz/1000000000))GB) exclude=$(paste -sd, "$mark") live=${pid:-none}" >&2

  if [[ -n $pid ]]; then
    for p in $pid; do killtree "$p"; done; sleep 2
    nohup bash -c "cd '$REPOS' && gunzip -c '$DST/$base.$m.olist.$l.gz' \
        | grep -Ev '(${pat});blob' \
        | perl -I '$HOME/lib64/perl5' '$HOME/bin/grabGitI.perl' '$DST/$base.$m.$l' \
        2> '$DST/$base.$m.$l.err'" >/dev/null 2>&1 &
  else
    gunzip -c "$DST/$base.$m.olist.$l.gz" | awk -F';' '$2=="blob"' | grep -Ev "(${pat});blob" \
      | perl -I "$HOME/lib64/perl5" "$HOME/bin/grabGitIType.perl" "$DST/$base.$m.$l.rb" blob \
      2> "$DST/$base.$m.$l.deoff.err"
    if [[ -s $DST/$base.$m.$l.rb.blob.idx ]]; then
      mv -f "$DST/$base.$m.$l.rb.blob.idx" "$DST/$base.$m.$l.blob.idx"
      mv -f "$DST/$base.$m.$l.rb.blob.bin" "$DST/$base.$m.$l.blob.bin"
    fi
  fi

  # log offenders (dedup by repo) with README/CLAUDE.md summary; size shown is
  # the aggregate (cross-shard) total when known, else the per-shard bytes
  for rp in "${!cand[@]}"; do
    grep -q "^${rp};" "$OFF" 2>/dev/null && continue
    gb=$(awk "BEGIN{printf \"%.1f\", ${cand[$rp]}/1e9}")
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
  for l in {00..15}; do
    bb=$DST/$base.$m.$l.blob.bin
    [[ -f $bb ]] && (( $(stat -c%s "$bb" 2>/dev/null || echo 0) > SHARD_MIN )) && { big=1; break; }
  done
  # also require no outstanding aggregate offender
  [[ -s $aggcache ]] && big=1
  if (( ! big )) && ! pgrep -f "grabGitI(Type)?\.perl .*/$base\.$m\." >/dev/null 2>&1; then
    echo "verified $(date '+%F %T') - safe to delete repos/dumps" > "$STAGEF"
  fi
fi
