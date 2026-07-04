#!/bin/bash
# parGrab.sh <V> <shard...>  -- grab the listed shards of dataset V IN PARALLEL (re-grab from
# existing clones + deduped olists, offenders/reference filtered out at grab time), then leave
# them for deoffdrainP/handleDataset to deoff+drain. Skips shards with a live grabGitI.
V=$1; shift
d=$([ -d /media/volume/b/V2605.$V ] && echo /media/volume/b/V2605.$V || echo /media/volume/out/V2605.$V)
base=New202605V2605; clonedir=/media/volume/trees/V2605.$V
[ -d "$clonedir" ] || { echo "parGrab $V: no clonedir"; exit 1; }
cut -d';' -f1 /media/volume/trees/offenders | LC_ALL=C sort -u > "$d/.offrepos"
grep -v '^#' /media/volume/trees/reference 2>/dev/null | cut -d';' -f1 | LC_ALL=C sort -u > "$d/.refrepos"
grep -vE '^#|^$' /media/volume/trees/dropcommit 2>/dev/null | cut -d';' -f1 | LC_ALL=C sort -u > "$d/.dcrepos"
cd "$clonedir" || exit 1
for l in "$@"; do
  pgrep -f "grabGitI.*$base\.$V\.$l\$" >/dev/null && { echo "  $V.$l already grabbing -- skip"; continue; }
  [ -f "$d/$base.$V.olist.$l.gz" ] || { echo "  $V.$l no olist -- skip"; continue; }
  echo "=== parGrab $V.$l START $(date '+%T') ==="
  pigz -dc "$d/$base.$V.olist.$l.gz" \
    | awk -F';' -v RF="$d/.refrepos" -v OF="$d/.offrepos" -v DC="$d/.dcrepos" '
        BEGIN{ while((getline x<RF)>0)ref[x]=1; while((getline x<OF)>0)off[x]=1; while((getline x<DC)>0)dc[x]=1 }
        ref[$1]{next} dc[$1]&&$2=="commit"{next} off[$1]&&($2=="blob"||$2=="tree"){next} {print}' \
    | perl -I "$HOME/lib64/perl5" "$HOME/bin/grabGitI.perl" "$d/$base.$V.$l" 2> "$d/$base.$V.$l.err" &
done
wait
echo "=== parGrab $V shards [$*] DONE $(date '+%F %T') ==="
