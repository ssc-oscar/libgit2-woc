#!/bin/bash
# deoffDa8.sh <prefix...>  -- RUNS ON da8. In-place standard deoff (blob+tree, keep
# commits/tags) of already-drained update-shards that accumulated offenders via
# late-registration. prefix = /mnt/ordos/data/data/update/V2605/New202605V2605.NNN.LL
# Uses /tmp/{filterDeoff.pl,offenders.da8,keep.da8,blobonly.da8} (shipped from clone0).
set -u
OFF=/tmp/offenders.da8; KEEP=/tmp/keep.da8; BO=/tmp/blobonly.da8
off1=/tmp/offlist.da8; cut -d';' -f1 "$OFF" | LC_ALL=C sort -u > "$off1"
for pre in "$@"; do
  [ -f "$pre.blob.idx" ] || { echo "## $pre absent -- skip"; continue; }
  ob=$(awk -F';' 'NR==FNR{o[$1]=1;next} o[$5]{n++}END{print n+0}' "$off1" "$pre.blob.idx")
  echo "=== $(basename "$pre") $(date '+%T'): orig blob=$(ls -lh $pre.blob.bin|awk '{print $5}'), offender-blobs=$ob ==="
  [ "$ob" -eq 0 ] && { echo "  already clean -- skip"; continue; }
  for t in blob tree; do
    [ -f "$pre.$t.idx" ] || continue
    perl /tmp/filterDeoff.pl "$t" "$pre" "$OFF" "$KEEP" "$BO" || { echo "  [$t] FAILED -- keep original"; rm -f "$pre.deoff.$t."{bin,idx}; continue; }
    if [ -f "$pre.deoff.$t.idx" ] && [ -f "$pre.deoff.$t.bin" ]; then
      # tiling sanity before swap
      mm=$(awk -F';' '{if($1+0!=e)m++; e=$1+$2} END{print m+0}' "$pre.deoff.$t.idx")
      sz=$(stat -c%s "$pre.deoff.$t.bin"); endo=$(awk -F';' '{e=$1+$2} END{print e+0}' "$pre.deoff.$t.idx")
      if [ "$mm" -eq 0 ] && [ "$sz" -eq "$endo" ]; then
        mv -f "$pre.deoff.$t.idx" "$pre.$t.idx"; mv -f "$pre.deoff.$t.bin" "$pre.$t.bin"
        echo "  [$t] swapped OK -> $(wc -l <$pre.$t.idx) objs, $(ls -lh $pre.$t.bin|awk '{print $5}')"
      else echo "  [$t] TILING BAD (mm=$mm sz=$sz end=$endo) -- NOT swapping"; rm -f "$pre.deoff.$t."{bin,idx}; fi
    fi
  done
  rb=$(awk -F';' 'NR==FNR{o[$1]=1;next} o[$5]{n++}END{print n+0}' "$off1" "$pre.blob.idx")
  echo "  DONE $(basename "$pre"): residual offender-blobs=$rb, new blob=$(ls -lh $pre.blob.bin|awk '{print $5}')"
done
echo "=== deoffDa8 ALL DONE $(date '+%F %T') ==="
