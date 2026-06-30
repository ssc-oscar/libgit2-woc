#!/bin/bash
# offsweepWatch.sh [maxhours]   (daemon; default 5h)
# Every ~30min, find each shard with a LIVE grabGitI that has been grabbing > maxhours and
# run offsweepShard <m> <l> kill on it -- detect+auto-register the dominant offender and KILL
# its sub-grab so a mega-dump can't drag a single shard's grab out to 24h+. Catches them early.
set -u
maxh=${1:-5}; thresh=$((maxh*3600))
echo "=== offsweepWatch start $(date '+%F %T'); flag grabs older than ${maxh}h ==="
while true; do
  for gp in $(pgrep -f 'grabGitI.perl .*New202605V2605' 2>/dev/null); do
    sh=$(tr '\0' ' ' </proc/$gp/cmdline 2>/dev/null | grep -oE 'V2605\.[0-9]+\.[0-9]+' | head -1)
    [ -z "$sh" ] && continue
    age=$(ps -o etimes= -p "$gp" 2>/dev/null | tr -d ' ')
    [ "${age:-0}" -ge "$thresh" ] || continue
    m=$(echo "$sh" | cut -d. -f2); l=$(echo "$sh" | cut -d. -f3)
    echo "[$(date '+%F %T')] long grab $sh age=$((age/3600))h -> offsweepShard kill"
    /home/exouser/bin/offsweepShard.sh "$m" "$l" kill
  done
  sleep 1800
done
