#!/bin/bash
# da8redeoff.sh [VER]  -- run on clone0. The GATE that re-deoffs da8 update shards against
# the CURRENT offenders registry before they are imported into the gen layer (convgen).
#
# Ships the live offenders/keep/blobonly + filterDeoff.pl + deoffDa8sweep.sh to da8, then
# runs the sweep over ALL drained update shards for VER (default V2605). Idempotent and
# safe to run periodically. Exits NONZERO if any shard could not be made clean -- callers
# (the gen-layer import) MUST check the exit code and NOT import on failure.
#
# Usage in the import workflow (run on clone0, gate convgen on da8):
#   da8redeoff.sh V2605 && ssh da8 'cd .../layered && ./convert_<...>.sh'   # only import if clean
set -u
VER="${1:-V2605}"
echo "=== da8redeoff $VER: shipping current registry + tools to da8 $(date '+%F %T') ==="
scp -q /media/volume/trees/offenders da8:/tmp/offenders.da8 || { echo "ABORT: ship offenders failed"; exit 2; }
scp -q /media/volume/trees/keep      da8:/tmp/keep.da8      || { echo "ABORT: ship keep failed"; exit 2; }
scp -q /media/volume/trees/blobonly  da8:/tmp/blobonly.da8  2>/dev/null || :
scp -q "$HOME/bin/filterDeoff.pl"    da8:/tmp/filterDeoff.pl || { echo "ABORT: ship filterDeoff.pl failed"; exit 2; }
scp -q "$HOME/bin/deoffDa8sweep.sh"  da8:/tmp/deoffDa8sweep.sh || { echo "ABORT: ship sweep failed"; exit 2; }
# verify the offender list landed non-empty on da8 before running (truncation/partial guard)
n=$(ssh da8 'wc -l < /tmp/offenders.da8 2>/dev/null' 2>/dev/null)
[ "${n:-0}" -ge 1000 ] || { echo "ABORT: da8 offenders.da8 only ${n:-0} lines (expected >=1000) -- not sweeping"; exit 2; }
echo "  registry on da8: $n entries; running sweep..."
ssh da8 "chmod +x /tmp/deoffDa8sweep.sh /tmp/filterDeoff.pl 2>/dev/null; bash /tmp/deoffDa8sweep.sh $VER"
rc=$?
echo "=== da8redeoff $VER exit=$rc ($([ $rc -eq 0 ] && echo 'CLEAN -- safe to import to gen layer' || echo 'DIRTY/FAILED -- do NOT import')) ==="
exit $rc
