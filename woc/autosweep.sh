#!/bin/bash
# autosweep.sh [intervalsec]  -- daemon: every cycle (default HOURLY) it
#   1. runs offsweepShard on every CHANGED local grab shard (blob.idx present) -> auto-registers
#      size/count/keyword dumps, logs borderline to /media/volume/trees/offsweep.review;
#   2. kill_live_offenders: SIGKILLs any live grabf/grabft whose repo is ALREADY a registered
#      offender, so grabGitI advances instead of dumping GBs that deoff will just strip. This
#      closes the gap offsweepShard's own 'kill' mode leaves (it only kills offenders NEWLY
#      auto-registered in the same pass, not ones registered manually or in a prior cycle while
#      their grab was already mid-repo -- e.g. a 66GB news-crawler that ran 2.5h before we noticed);
#   3. captures dropcommit tips.
# Idempotent (offsweepShard skips already-registered; per-shard mtime marker skips unchanged shards).
set -u
INT=${1:-3600}   # HOURLY
MARK=/tmp/autosweep.marks; mkdir -p "$MARK"
OFFENDERS=/media/volume/trees/offenders
LOG=/media/volume/trees/autosweep.log

# Kill any running grab of a repo already in the offenders registry (output would be deoff-stripped).
kill_live_offenders() {
  [ -s "$OFFENDERS" ] || return 0
  local ofile; ofile=$(mktemp /tmp/klo.XXXXXX) || return 0
  cut -d';' -f1 "$OFFENDERS" | sort -u > "$ofile"
  local killed=0
  # match grabf AND grabft (repo = last field); covers both the bare binary and the `cat .. | grabf repo` wrapper
  while read -r pid repo; do
    [ -n "$pid" ] && [ -n "$repo" ] || continue
    if grep -qxF "$repo" "$ofile"; then
      if kill -9 "$pid" 2>/dev/null; then
        echo "[$(date '+%F %T')] kill_live_offenders: killed pid=$pid repo=$repo (registered offender)" >> "$LOG"
        killed=$((killed+1))
      fi
    fi
  done < <(pgrep -af '/grabf' | awk '$0 ~ /\/grabf[t]? / {print $1, $NF}')
  [ "$killed" -gt 0 ] && echo "[$(date '+%F %T')] kill_live_offenders: $killed live offender grab(s) killed" >> "$LOG"
  rm -f "$ofile"
}

echo "=== autosweep start $(date '+%F %T'); interval ${INT}s ==="
while true; do
  for f in /media/volume/b/V2605.*/New202605V2605.*.blob.idx /media/volume/out/V2605.*/New202605V2605.*.blob.idx; do
    [ -f "$f" ] || continue
    sh=$(echo "$f" | grep -oE 'V2605\.[0-9]+\.[0-9]+' | head -1); [ -z "$sh" ] && continue
    m=$(echo "$sh" | cut -d. -f2); l=$(echo "$sh" | cut -d. -f3)
    mt=$(stat -c %Y "$f" 2>/dev/null); mk="$MARK/$m.$l"
    [ -f "$mk" ] && [ "$(cat "$mk" 2>/dev/null)" = "$mt" ] && continue   # unchanged since last sweep
    /home/exouser/bin/offsweepShard.sh "$m" "$l" >> "$LOG" 2>&1
    echo "$mt" > "$mk"
  done
  kill_live_offenders               # after detection: kills grabs of dumps registered THIS cycle too
  /home/exouser/bin/captureDropcommitTips.sh V2605 >> /media/volume/trees/dctips.log 2>&1
  sleep "$INT"
done
