#!/bin/bash
# deoffFull.sh <prefix> [offenders] [keep]
#
# ##############################################################################
# # HACK -- SPECIAL SITUATIONS ONLY. NOT part of the normal pipeline.          #
# # Do NOT wire this into runExo/cron/sweeps. The routine offender treatment   #
# # is production deOffend.sh / filterDeoff.pl, which KEEP offender commits     #
# # (commit-only). Use this ONLY for a deliberate one-off salvage where you     #
# # are re-homing the offender commits into a separate shard and therefore      #
# # want the source shard stripped of offender commits too.                     #
# ##############################################################################
#
# Full offender removal from an EXISTING shard's bins, IN PLACE: drops offender
# blob+tree+COMMIT (tags untouched -- never offender-bearing in observed shards).
# Differs from production deOffend.sh / filterDeoff.pl default (which keep offender
# commits). Does NOT touch deOffend.sh.
#
# History: created 2026-06-29 for the V2605.139.15 salvage (kill a multi-day grab
# mid-offender, deoff shard 15 fully clean, re-home offender commits into shard 16)
# to avoid repeating the grab. See coord/clone0 / session notes.
#
# <prefix> = path up to but excluding ".<type>" e.g.
#   /media/volume/out/V2605.139/New202605V2605.139.15
set -u
prefix=${1:?usage: deoffFull.sh <prefix-without-.type> [offenders] [keep]}
OFF=${2:-/media/volume/trees/offenders}
KEEP=${3:-/media/volume/trees/keep}
for t in blob tree commit; do
  [[ -f $prefix.$t.idx && -f $prefix.$t.bin ]] || { echo "  [$t] no bins, skip"; continue; }
  # offenders as BOTH the offenders-file (drops blob/tree) AND the dropcommit-file
  # (drops commit) => full removal of every offender object of this type.
  perl "$HOME/bin/filterDeoff.pl" "$t" "$prefix" "$OFF" "$KEEP" "" "$OFF" || { echo "  [$t] filterDeoff FAILED"; exit 1; }
  if [[ -f $prefix.deoff.$t.idx && -f $prefix.deoff.$t.bin ]]; then
    mv -f "$prefix.deoff.$t.idx" "$prefix.$t.idx"
    mv -f "$prefix.deoff.$t.bin" "$prefix.$t.bin"
    echo "  [$t] removed offenders in place -> $(wc -l < "$prefix.$t.idx") objects remain"
  else
    echo "  [$t] no .deoff output (nothing dropped?)"
  fi
done
