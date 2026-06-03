#!/bin/bash
# Watchdog (run periodically from cron, concurrently with the long grabs):
#  1. de-offend any dataset/shard whose blob.bin grew oversized (>100GB) --
#     deOffend.sh kills+relaunches a still-running grab excluding the dominant
#     repo, or re-extracts blobs for a finished shard;
#  2. verify datasets that runExo has rsynced (repo-folder STAGE=rsynced) and,
#     once nothing is left to de-offend, upgrade STAGE to "verified".
# A dataset's dumps live on EITHER /media/volume/out OR /media/volume/b
# depending on the batch, so the disk is resolved per dataset by where its
# dump files actually are (not by mere directory existence).
# Datasets marked done (being deleted) or whose repos are gone are skipped.
# deOffend.sh holds a per-dataset lock, so this never races the inline runExo loop.
export HOME=/home/exouser
export PATH=/usr/local/bin:/usr/bin:/bin
. "${WOC_CONFIG:-$HOME/bin/jetstream2.config}" 2>/dev/null
: "${VOL:=/media/volume}"; : "${TREES:=$VOL/trees}"; : "${DUMP_DIRS:=out b}"
DONE=$HOME/bin/wocFixErr.done

# echo the dump disk (one of $DUMP_DIRS) that holds dataset $1's dumps, else nothing
root_for(){ local ds=$1 r
  for r in $DUMP_DIRS; do
    compgen -G "$VOL/$r/$ds/New202605${ds}.olist.*.gz" >/dev/null 2>&1 && { echo "$r"; return; }
  done
}

declare -A todo
# datasets with an oversized blob.bin (on either dump disk)
for root in $DUMP_DIRS; do
  for binf in $VOL/$root/V2605.*/New202605V2605.*.blob.bin; do
    [[ -f $binf ]] || continue
    (( $(stat -c%s "$binf" 2>/dev/null || echo 0) > 100000000000 )) && todo["$(basename "$(dirname "$binf")")"]=1
  done
done
# datasets rsynced but not yet verified (STAGE marker in the repo folder)
for stagef in $TREES/V2605.*/STAGE; do
  [[ -f $stagef ]] || continue
  grep -q '^rsynced' "$stagef" 2>/dev/null && todo["$(basename "$(dirname "$stagef")")"]=1
done

for ds in "${!todo[@]}"; do
  grep -qxF "$ds" "$DONE" 2>/dev/null && continue          # finalized/being deleted
  [[ -d $TREES/$ds ]] || continue                          # repos gone -> nothing to do
  root=$(root_for "$ds"); [[ -z $root ]] && continue       # dumps already gone
  "$HOME/bin/deOffend.sh" "${ds#V2605.}" V2605 "$root"
done
