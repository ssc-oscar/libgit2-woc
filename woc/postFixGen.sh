#!/bin/bash
# postFixGen.sh -- run AFTER fixGenLayer.sh cleaned commit+tree gen (gen minus base).
# Rebuilds the layered offset maps, re-records the shrunken watermarks, and regenerates the
# per-version new-object .cs (now base-tail UNION gen_clean = disjoint + no V2604 leak).
# Diffs/reads must stay STOPPED until the offset maps finish.
set -eu
LOOKUP=${LOOKUP:-$HOME/lookup}
SHA1O=${SHA1O:-/fast/All.sha1o}
UD=${UD:-/data/home/audris/update}
CSOUT=${CSOUT:-/da8_data/update/V2605d}

echo "=== 1) rebuild offset maps (commit+tree, 0..127) over base + cleaned gen $(date) ==="
for spec in "commit CmtN2OffGen.perl" "tree TreeN2OffGen.perl"; do
  set -- $spec; TYPE=$1; OG=$2
  # rebuild from scratch: remove stale maps first so a partial/append can't linger
  rm -f "$SHA1O"/sha1.${TYPE}_*.tch
  seq 0 127 | xargs -P6 -I{} sh -c "LAYERED=/fast/All.blobsGen perl $LOOKUP/$OG {} >/dev/null 2>>$SHA1O/offgen.$TYPE.err"
  echo "  $TYPE offsets: $(ls "$SHA1O"/sha1.${TYPE}_*.tch 2>/dev/null | wc -l)/128"
done

echo "=== 2) re-record layered watermarks (gen shrank) $(date) ==="
/tmp/mkNewObjList.sh record commit V2605
/tmp/mkNewObjList.sh record tree   V2605

echo "=== 3) regenerate all 128 .cs (base-tail UNION gen_clean) $(date) ==="
/tmp/mkNewObjList.sh newlist commit V2604 V2605 "$CSOUT"
echo "=== postFixGen COMPLETE $(date) ==="
