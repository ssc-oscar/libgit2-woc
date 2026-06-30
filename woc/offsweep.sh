#!/bin/bash
# offsweep.sh [minGB]  -- largest.sh across ALL live local grab shards (b+out), aggregated.
# Sums blob AND tree stored-bytes per repo across every local New202605V2605.*.{blob,tree}.idx,
# then lists repos whose total footprint >= minGB that are NOT already in offenders/keep --
# i.e. candidate offenders that slipped past the manual per-shard largest.sh pastes.
LC_ALL=C
min=${1:-2}
REG=/media/volume/trees/offenders; KEEP=/media/volume/trees/keep
cut -d';' -f1 "$REG" 2>/dev/null | sort -u > /tmp/off.set
grep -vE '^#|^$' "$KEEP" 2>/dev/null | sort -u > /tmp/keep.set
# per-repo total bytes (blob+tree) and which shard had the most, across all live shards
for f in /media/volume/b/V2605.*/New202605V2605.*.blob.idx /media/volume/b/V2605.*/New202605V2605.*.tree.idx \
         /media/volume/out/V2605.*/New202605V2605.*.blob.idx /media/volume/out/V2605.*/New202605V2605.*.tree.idx; do
  [ -f "$f" ] || continue
  ds=$(echo "$f" | grep -oE 'V2605\.[0-9]+\.[0-9]+' | head -1)
  awk -F';' -v D="$ds" '{s[$5]+=$2} END{for(r in s) print s[r]";"r";"D}' "$f"
done | awk -F';' '{tot[$2]+=$1; if($1>best[$2]){best[$2]=$1; where[$2]=$3}} END{for(r in tot) print tot[r]";"r";"where[r]}' \
  | sort -rn \
  | awk -F';' -v min="$min" '
      BEGIN{while((getline x < "/tmp/off.set")>0)o[x]=1; while((getline x < "/tmp/keep.set")>0)k[x]=1}
      $1/1e9>=min && !($2 in o) && !($2 in k){printf "%8.1fGB  %-50s (top shard %s)\n",$1/1e9,$2,$3}'
