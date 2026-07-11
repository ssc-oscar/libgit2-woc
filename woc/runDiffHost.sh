#!/bin/bash
# runDiffHost.sh <P> <sec...>   -- run V2604->V2605 diffs for this host's assigned sections,
# at most P concurrent (xargs -P), resumable (runDiff.sh skips sections with a .done marker).
# DiffT vs DiffCT is chosen by the caller's environment:
#   da5 : export COMMIT_CONTENT=/fast/All.sha1c   (DiffT, base commits via content)
#   da3/da4 : leave COMMIT_CONTENT unset          (DiffCT, base commits via offset)
# MAXTREE default 250000 (skip monster roots -> cLarge). Outputs land in da8:update/V2605d.
set -u
P=${1:?usage: runDiffHost.sh <P> <startSec> <endSec>}; START=${2:?startSec}; END=${3:?endSec}
export MAXTREE=${MAXTREE:-250000}
echo "=== runDiffHost $(hostname) P=$P sections=$START..$END DiffT=${COMMIT_CONTENT:-no} $(date) ==="
seq "$START" "$END" | xargs -P"$P" -I{} bash /da5_fast/bin/runDiff.sh {}
echo "=== runDiffHost $(hostname) ALL ASSIGNED DONE $(date) ==="
