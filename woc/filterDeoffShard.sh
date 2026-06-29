#!/bin/bash
# In-place offender removal for one shard: filterDeoffShard.sh VER SHARD
# Filters blob + tree (commit/tag untouched -- never dropped). No clones needed.
V="$1"; l="$2"; [ -z "$V" ] || [ -z "$l" ] && { echo "usage: filterDeoffShard.sh VER SHARD"; exit 1; }
base=New202605V2605
d=""
for cand in /media/volume/b/V2605.$V /media/volume/out/V2605.$V; do
  [ -f "$cand/$base.$V.$l.blob.idx" ] && { d="$cand"; break; }
done
[ -z "$d" ] && { echo "no grab dir/idx for $V.$l"; exit 1; }
OFF=/media/volume/trees/offenders; KEEP=/media/volume/trees/keep; BO=/media/volume/trees/blobonly
pre="$d/$base.$V.$l"
echo "=== filterDeoff $V.$l START $(date '+%F %T'); orig $(du -shc $pre.{blob,tree}.bin 2>/dev/null|tail -1|cut -f1) ==="
for t in blob tree; do
  [ -s "$pre.$t.idx" ] || { echo "  [$t] no idx -- skip"; continue; }
  perl "$HOME/bin/filterDeoff.pl" "$t" "$pre" "$OFF" "$KEEP" "$BO" || { echo "  [$t] FILTER FAILED -- leaving original"; rm -f "$pre.deoff.$t.bin" "$pre.deoff.$t.idx"; continue; }
  # swap in only if a new idx was produced
  if [ -f "$pre.deoff.$t.idx" ]; then
    mv -f "$pre.deoff.$t.idx" "$pre.$t.idx"
    mv -f "$pre.deoff.$t.bin" "$pre.$t.bin"
    echo "  [$t] swapped in"
  fi
done
echo "=== filterDeoff $V.$l DONE $(date '+%F %T'); new $(du -shc $pre.{blob,tree}.bin 2>/dev/null|tail -1|cut -f1) ==="
