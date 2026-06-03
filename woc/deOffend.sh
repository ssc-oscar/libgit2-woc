#!/bin/bash
# Shrink oversized per-shard blob dumps by excluding repos whose blobs dominate.
# Safe to call repeatedly (e.g. every 30 min) WHILE the grab is still running --
# grabbing some repos can take days, so we don't wait for the whole shard.
#
# For each shard whose blob.bin > SHARD_MIN, find repos contributing > REPO_MIN
# of (compressed) blob bytes (from the possibly-partial blob.idx):
#   * if a grabGitI worker for that shard is still running, kill it and relaunch
#     the FULL grab excluding the offenders' blobs (in the background);
#   * if the shard's grab already finished, re-extract its BLOBS only excluding
#     the offenders and swap in the smaller dump (commit/tree/tag left intact).
# Each offender is appended once to ~/trees/offenders as
#   repo;size;excluded <date>;summary
# A per-shard marker (<base>.<l>.excluded) accumulates excluded repos so we do
# not repeatedly kill the same relaunched grab.
#
#   deOffend.sh <m> <ver> [out]      e.g.  deOffend.sh 030 V2605 out
m=$1; ver=$2; out=${3:-out}; DT=202605; base=New$DT$ver
. "${WOC_CONFIG:-$HOME/bin/jetstream2.config}" 2>/dev/null
: "${VOL:=/media/volume}"; : "${TREES:=$VOL/trees}"; : "${OFFENDERS:=$TREES/offenders}"
DST=$VOL/$out/$ver.$m
REPOS=$TREES/$ver.$m
OFF=$OFFENDERS
SHARD_MIN=100000000000      # 100 GB
REPO_MIN=30000000000        #  30 GB

# per-dataset lock so the inline runExo loop and the cron watchdog never act on
# the same dataset at once (non-blocking: if busy, another instance has it)
exec 9>"/tmp/deOffend.$ver.$m.lock" 2>/dev/null
flock -n 9 || exit 0

[[ -d $REPOS ]] || exit 0
cd "$REPOS" || exit 0
today=$(date +%F)
killtree(){ local p=$1 c; for c in $(pgrep -P "$p" 2>/dev/null); do killtree "$c"; done; kill -TERM "$p" 2>/dev/null; }

for l in {00..15}; do
  binf=$DST/$base.$m.$l.blob.bin
  [[ -f $binf ]] || continue
  sz=$(stat -c%s "$binf"); (( sz > SHARD_MIN )) || continue

  # offenders (bytes;repo) from the (possibly partial) blob.idx, largest first
  mapfile -t offs < <("$HOME/bin/largest.sh" "$DST/$base.$m.$l.blob" \
                      | awk -F';' -v t=$REPO_MIN '$1>t{print $1";"$2}')
  (( ${#offs[@]} )) || continue

  # accumulate excluded repos in a marker; only act if there is a NEW one
  mark=$DST/$base.$m.$l.excluded; touch "$mark"; newoff=0
  for o in "${offs[@]}"; do r=${o#*;}
    grep -qxF "$r" "$mark" || { echo "$r" >> "$mark"; newoff=1; }
  done
  (( newoff )) || continue          # offenders already being excluded by a relaunch
  pat=$(paste -sd'|' "$mark")

  pid=$(pgrep -f "grabGitI(Type)?\.perl .*/$base\.$m\.$l\$")
  echo "[deOffend $(date '+%F %T')] $base.$m.$l ($((sz/1000000000))GB) exclude=$(paste -sd, "$mark") live=${pid:-none}" >&2

  if [[ -n $pid ]]; then
    # still grabbing: kill the worker subtree, relaunch FULL grab w/o offenders
    for p in $pid; do killtree "$p"; done
    sleep 2
    nohup bash -c "cd '$REPOS' && gunzip -c '$DST/$base.$m.olist.$l.gz' \
        | grep -Ev '(${pat});blob' \
        | perl -I '$HOME/lib64/perl5' '$HOME/bin/grabGitI.perl' '$DST/$base.$m.$l' \
        2> '$DST/$base.$m.$l.err'" >/dev/null 2>&1 &
  else
    # shard finished: re-extract blobs only without offenders, swap in
    gunzip -c "$DST/$base.$m.olist.$l.gz" | awk -F';' '$2=="blob"' | grep -Ev "(${pat});blob" \
      | perl -I "$HOME/lib64/perl5" "$HOME/bin/grabGitIType.perl" "$DST/$base.$m.$l.rb" blob \
      2> "$DST/$base.$m.$l.deoff.err"
    if [[ -s $DST/$base.$m.$l.rb.blob.idx ]]; then
      mv -f "$DST/$base.$m.$l.rb.blob.idx" "$DST/$base.$m.$l.blob.idx"
      mv -f "$DST/$base.$m.$l.rb.blob.bin" "$DST/$base.$m.$l.blob.bin"
    fi
  fi

  # log offenders (dedup by repo) with README/CLAUDE.md summary
  for o in "${offs[@]}"; do
    bytes=${o%%;*}; repo=${o#*;}
    grep -q "^${repo};" "$OFF" 2>/dev/null && continue
    gb=$(awk "BEGIN{printf \"%.1f\", $bytes/1e9}")
    summ=$("$HOME/bin/readmeSummary.sh" "$REPOS/$repo")
    printf '%s;%sGB;excluded %s;%s\n' "$repo" "$gb" "$today" "$summ" >> "$OFF"
  done
done

# verification: once runExo has rsynced (STAGE=rsynced) and there is nothing
# left to de-offend (no shard >SHARD_MIN, no grab running), upgrade the repo
# folder's STAGE marker to "verified" -- safe to delete repo clones and dumps.
STAGEF=$REPOS/STAGE
if [[ -f $STAGEF ]] && grep -q '^rsynced' "$STAGEF" 2>/dev/null; then
  big=0
  for l in {00..15}; do
    b=$DST/$base.$m.$l.blob.bin
    [[ -f $b ]] && (( $(stat -c%s "$b" 2>/dev/null || echo 0) > SHARD_MIN )) && { big=1; break; }
  done
  if (( ! big )) && ! pgrep -f "grabGitI(Type)?\.perl .*/$base\.$m\." >/dev/null 2>&1; then
    echo "verified $(date '+%F %T') - safe to delete repos/dumps" > "$STAGEF"
  fi
fi
