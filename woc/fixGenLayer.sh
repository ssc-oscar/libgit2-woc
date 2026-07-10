#!/bin/bash
# fixGenLayer.sh <type>   -- clean all 128 sections of <type>_gen1 = gen MINUS base.
# Removes objects duplicated in base (irregular V2604->V2605 transition wrote ~734M into both
# base and gen). Per section: genMinusBase -> .clean, assert kept+dropped==orig, swap in place,
# reclaim .old (bounded disk peak). Resumable (per-section .done marker). Offset maps + watermarks
# + .cs must be rebuilt AFTER this (gen offsets change).  Run with diffs/reads STOPPED.
set -eu
T=${1:?usage: fixGenLayer.sh <commit|tree>}
BASE=${BASE:-/da5_data/All.blobs}
G=${G:-/fast/All.blobsGen/${T}_gen1}
LOG=/tmp/fixGen_$T.log
echo "=== fixGenLayer $T START $(date) ===" | tee -a "$LOG"
for s in $(seq 0 127); do
  gi=$G/${T}_$s.idx; gb=$G/${T}_$s.bin; bi=$BASE/${T}_$s.idx
  [ -f "$gi.fixed" ] && { echo "sec $s already fixed" | tee -a "$LOG"; continue; }
  orig=$(wc -l < "$gi")
  /da5_fast/bin/genMinusBase "$bi" "$gi" "$gb" "$gi.clean" "$gb.clean" 2>>"$LOG"
  kept=$(wc -l < "$gi.clean"); dropped=$((orig-kept))
  # sanity: clean must be non-empty and strictly smaller (there IS overlap in every section)
  if [ "$kept" -le 0 ] || [ "$kept" -ge "$orig" ]; then
    echo "ABORT sec $s: orig=$orig kept=$kept (no drop or empty) -- leaving originals" | tee -a "$LOG"; exit 1
  fi
  mv "$gi" "$gi.old"; mv "$gb" "$gb.old"
  mv "$gi.clean" "$gi"; mv "$gb.clean" "$gb"
  rm -f "$gi.old" "$gb.old"
  touch "$gi.fixed"
  echo "sec $s: orig=$orig kept=$kept dropped=$dropped $(date)" | tee -a "$LOG"
done
echo "=== fixGenLayer $T COMPLETE $(date) ===" | tee -a "$LOG"
