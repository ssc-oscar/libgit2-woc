#!/bin/bash
# deoffDa8sweep.sh [VER]  -- RUNS ON da8.
# Re-deoff EVERY drained update-shard for VER against the CURRENT offenders registry
# (shipped to /tmp/{offenders,keep,blobonly}.da8 + /tmp/filterDeoff.pl by da8redeoff.sh).
# Idempotent: shards already free of offenders are scanned (cheap idx pass) and left
# untouched; only shards carrying offenders are rewritten in place. Standard treatment:
# drop offender blob+tree, KEEP commit/tag.
#
# PURPOSE: previously-drained shards accumulate offenders as the registry GROWS
# (offender classified AFTER the shard drained = "late registration"). This sweep is the
# GATE that MUST run before importing update shards into the gen layer (convgen), so no
# offender blob/tree ever enters the layered store. Also safe to run periodically.
set -u
VER="${1:-V2605}"
UD="/mnt/ordos/data/data/update/$VER"
OFF=/tmp/offenders.da8; KEEP=/tmp/keep.da8; BO=/tmp/blobonly.da8
off1=/tmp/offlist.da8
cut -d';' -f1 "$OFF" 2>/dev/null | LC_ALL=C sort -u > "$off1"
# SAFETY: an empty offender list means a bad/aborted ship -- never proceed (would no-op
# silently and let dirty shards through the gate).
[ -s "$off1" ] || { echo "ABORT: offender list empty/missing ($OFF) -- not sweeping $VER"; exit 1; }
cd "$UD" 2>/dev/null || { echo "ABORT: no $UD"; exit 1; }
scanned=0; dirty=0; cleaned=0; failed=0
for bi in New*${VER}.[0-9]*.[0-9]*.blob.idx; do
  [ -f "$bi" ] || continue
  pre="${bi%.blob.idx}"; scanned=$((scanned+1))
  pgrep -f "filterDeoff.pl (blob|tree) .*$pre\$" >/dev/null 2>&1 && { echo "## $pre deoff already running -- skip"; continue; }
  ob=$(awk -F';' 'NR==FNR{o[$1]=1;next} o[$5]{n++}END{print n+0}' "$off1" "$bi")
  [ "${ob:-0}" -eq 0 ] && continue
  dirty=$((dirty+1))
  echo "=== DEOFF $pre $(date '+%T'): offender-blobs=$ob blob=$(ls -lh $pre.blob.bin 2>/dev/null|awk '{print $5}') ==="
  ok=1
  for t in blob tree; do
    [ -f "$pre.$t.idx" ] || continue
    if ! perl /tmp/filterDeoff.pl "$t" "$pre" "$OFF" "$KEEP" "$BO"; then echo "  [$t] FILTER FAILED"; rm -f "$pre.deoff.$t."{bin,idx}; ok=0; continue; fi
    if [ -f "$pre.deoff.$t.idx" ] && [ -f "$pre.deoff.$t.bin" ]; then
      mm=$(awk -F';' '{if($1+0!=e)m++; e=$1+$2} END{print m+0}' "$pre.deoff.$t.idx")
      sz=$(stat -c%s "$pre.deoff.$t.bin"); endo=$(awk -F';' '{e=$1+$2} END{print e+0}' "$pre.deoff.$t.idx")
      if [ "${mm:-1}" -eq 0 ] && [ "${sz:-1}" -eq "${endo:-0}" ]; then
        mv -f "$pre.deoff.$t.idx" "$pre.$t.idx"; mv -f "$pre.deoff.$t.bin" "$pre.$t.bin"
        echo "  [$t] OK -> $(wc -l <$pre.$t.idx) objs ($(ls -lh $pre.$t.bin|awk '{print $5}'))"
      else echo "  [$t] TILING BAD (mm=$mm sz=$sz end=$endo) -- NOT swapping"; rm -f "$pre.deoff.$t."{bin,idx}; ok=0; fi
    fi
  done
  rb=$(awk -F';' 'NR==FNR{o[$1]=1;next} o[$5]{n++}END{print n+0}' "$off1" "$bi")
  if [ "${rb:-1}" -eq 0 ] && [ "$ok" -eq 1 ]; then cleaned=$((cleaned+1)); echo "  CLEANED $pre"; else failed=$((failed+1)); echo "  $pre RESIDUAL=$rb ok=$ok -- NOT clean"; fi
done
echo "=== deoffDa8sweep $VER DONE $(date '+%F %T'): scanned=$scanned dirty=$dirty cleaned=$cleaned failed=$failed ==="
[ "$failed" -eq 0 ]   # nonzero exit if any shard left dirty -> import gate must NOT proceed
