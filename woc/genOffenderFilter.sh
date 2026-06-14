#!/bin/bash
# genOffenderFilter.sh [outdir]
#
# Materialize the clone-stage offender filter lists from woc.pm (the single
# authoritative exclusion source). doOtrVerFetch.sh reads these to avoid cloning
# the garbage content of known offenders:
#   <outdir>/offenders.treeSkip : repos with large/garbage TREES  -> fetch tree:0 (commits only)
#   <outdir>/offenders.blobSkip : repos with garbage BLOBS        -> fetch blob:none (commits+trees)
#
# Keys come from woc::%largeTreePrj / woc::%largeBlobPrj (which now include the
# imported deOffend offenders registry). Writes atomically; on any failure
# (woc.pm not loadable here) it leaves existing lists untouched so the clone
# stage degrades to its normal full-fetch behavior.
set -u
LOOKUP=${LOOKUP:-$HOME/lookup}
OUT=${1:-$HOME/bin}
mkdir -p "$OUT"
for kind in largeTreePrj:treeSkip largeBlobPrj:blobSkip; do
  hash=${kind%%:*}; file=${kind##*:}
  if perl -I "$LOOKUP" -Mwoc -e "print \"\$_\n\" for keys %woc::$hash" 2>/dev/null \
       | sort -u > "$OUT/offenders.$file.tmp" && [ -s "$OUT/offenders.$file.tmp" ]; then
    mv -f "$OUT/offenders.$file.tmp" "$OUT/offenders.$file"
  else
    rm -f "$OUT/offenders.$file.tmp"
    echo "[genOffenderFilter] WARN: could not generate $file from woc.pm; keeping existing" >&2
  fi
done
echo "[genOffenderFilter] treeSkip=$(wc -l < "$OUT/offenders.treeSkip" 2>/dev/null || echo 0) blobSkip=$(wc -l < "$OUT/offenders.blobSkip" 2>/dev/null || echo 0)"
