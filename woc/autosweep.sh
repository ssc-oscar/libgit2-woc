#!/bin/bash
# autosweep.sh [intervalsec]  -- daemon: periodically run offsweepShard on EVERY local grab
# shard (blob.idx present), auto-registering size/count/keyword dumps + logging borderline to
# /media/volume/trees/offsweep.review. Idempotent (offsweepShard skips already-registered).
# Uses a per-shard "swept" marker keyed on the idx mtime so unchanged shards aren't re-swept.
set -u
INT=${1:-1200}   # 20 min
MARK=/tmp/autosweep.marks; mkdir -p "$MARK"
echo "=== autosweep start $(date '+%F %T'); interval ${INT}s ==="
while true; do
  for f in /media/volume/b/V2605.*/New202605V2605.*.blob.idx /media/volume/out/V2605.*/New202605V2605.*.blob.idx; do
    [ -f "$f" ] || continue
    sh=$(echo "$f" | grep -oE 'V2605\.[0-9]+\.[0-9]+' | head -1); [ -z "$sh" ] && continue
    m=$(echo "$sh" | cut -d. -f2); l=$(echo "$sh" | cut -d. -f3)
    mt=$(stat -c %Y "$f" 2>/dev/null); mk="$MARK/$m.$l"
    [ -f "$mk" ] && [ "$(cat "$mk" 2>/dev/null)" = "$mt" ] && continue   # unchanged since last sweep
    /home/exouser/bin/offsweepShard.sh "$m" "$l" >> /media/volume/trees/autosweep.log 2>&1
    echo "$mt" > "$mk"
  done
  sleep "$INT"
done
