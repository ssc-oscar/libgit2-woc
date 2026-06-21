#!/bin/bash
# convert_backlog.sh <type> <min_dataset> [capbits] [nbands]
# Convert all da8 backlog batches of <type> (datasets >= min) into one clean,
# deduped gen on da8, then build .sidx + .bf once per sec.
#   - phase 1: ONE convgen process per sec-band (seen-set dedups across ALL
#     batches; nbands>1 splits secs to bound RAM, e.g. blobs).
#   - phase 2: sidx + bf per sec (parallel).
# Resumable: convgen seeds its seen-set from the existing gen idx, so re-running
# skips already-stored objects.
set -u
TYPE=${1:?type}; MIN=${2:-0}; CAPBITS=${3:-28}; NBANDS=${4:-1}
D=/mnt/ordos/data/data/update/V2605
GEN=/mnt/ordos/data/data/layered/V2605/${TYPE}_gen1
BIN=/tmp/conv
EXCLUDE=${EXCLUDE:-}            # comma-sep datasets to skip (e.g. in-flight rsync)
MINAGE=${MINAGE:-20}           # skip batches whose .idx/.bin changed < MINAGE min (in-flight)
mkdir -p "$GEN"
LIST="$GEN/.batches"

# rsync-safety: a dataset is UNSAFE if it has an rsync temp file (.New<...>.<ds>.*)
# or any final batch modified within MINAGE minutes (mid-rename), or is in EXCLUDE.
unsafe=" $(echo "$EXCLUDE" | tr ',' ' ') "
for ds in $(ls $D/.New202605V2605.*.* 2>/dev/null | sed -E 's#.*/\.New202605V2605\.([0-9]+)\..*#\1#' | sort -u); do unsafe="$unsafe$ds "; done
for ds in $(find $D -maxdepth 1 -name "New202605V2605.*.${TYPE}.*" -mmin -"$MINAGE" 2>/dev/null | sed -E 's/.*V2605\.([0-9]+)\..*/\1/' | sort -u); do unsafe="$unsafe$ds "; done
echo "[$(date +%T)] unsafe (in-flight) datasets skipped: $(echo $unsafe | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u | tr '\n' ' ')"

ls $D/New202605V2605.*.${TYPE}.idx 2>/dev/null \
  | sed -E 's/.*V2605\.([0-9]+)\..*/\1 &/' \
  | awk -v m="$MIN" -v U=" $(echo $unsafe|tr -s ' ') " '$1+0>=m && index(U," "$1" ")==0{print $2}' \
  | sed "s/\.${TYPE}\.idx\$//" > "$LIST"
nb=$(wc -l < "$LIST")
echo "[$(date +%T)] $TYPE: $nb batches (datasets>=$MIN), capbits=$CAPBITS, bands=$NBANDS"
[ "$nb" -gt 0 ] || { echo "nothing to convert"; exit 0; }

# phase 1: append (deduped) -- one convgen per band
step=$(( (128 + NBANDS - 1) / NBANDS ))
for ((b=0;b<NBANDS;b++)); do
  a=$((b*step)); z=$((a+step-1)); [ $z -gt 127 ] && z=127
  echo "[$(date +%T)] band secs $a..$z"
  $BIN/convgen "$TYPE" "$GEN" --capbits "$CAPBITS" --secmin "$a" --secmax "$z" -L "$LIST" \
    2>>"$GEN/convgen.log" || { echo "convgen band $a..$z FAILED"; exit 1; }
done
echo "[$(date +%T)] phase2: build .sidx + .bf per sec"
ls $GEN/${TYPE}_*.idx 2>/dev/null | xargs -P8 -I{} bash -c '
  b="${1%.idx}"; '"$BIN"'/sidx build "$1" "$b.sidx" 2>>'"$GEN"'/index.err
  perl '"$BIN"'/extract_sha.pl "$1" | '"$BIN"'/build_bf "$b.bf" 2>>'"$GEN"'/index.err >/dev/null' _ {}
echo "[$(date +%T)] DONE $TYPE: bin=$(ls $GEN/${TYPE}_*.bin 2>/dev/null|wc -l) sidx=$(ls $GEN/${TYPE}_*.sidx 2>/dev/null|wc -l) bf=$(ls $GEN/${TYPE}_*.bf 2>/dev/null|wc -l) size=$(du -sh $GEN 2>/dev/null|cut -f1)"
