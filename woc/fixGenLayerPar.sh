#!/bin/bash
# fixGenLayerPar.sh <type> [P]  -- PARALLEL per-section gen-minus-base clean+swap.
# Sections are independent files, so fan out P at a time. Each worker: genMinusBase -> .clean,
# assert 0<kept<orig, atomic swap, reclaim .old. Resumable (.fixed marker). Disk peak ~ P sections'
# .clean extra. Use for the big tree pass. genMinusBase loads a ~5.4GB base hash per worker.
set -u
T=${1:?usage: fixGenLayerPar.sh <commit|tree> [P]}
P=${2:-6}
export T
BASE=/da5_data/All.blobs
export G=/fast/All.blobsGen/${T}_gen1
LOG=/tmp/fixGen_${T}.log
echo "=== fixGenLayerPar $T P=$P START $(date) ===" | tee -a "$LOG"
fixone(){
  s=$1
  local gi="$G/${T}_$s.idx" gb="$G/${T}_$s.bin" bi="/da5_data/All.blobs/${T}_$s.idx"
  [ -f "$gi.fixed" ] && { echo "sec $s already fixed"; return 0; }
  local orig kept
  orig=$(wc -l < "$gi")
  /da5_fast/bin/genMinusBase "$bi" "$gi" "$gb" "$gi.clean" "$gb.clean" 2>>"/tmp/fixGen_${T}.log" || { echo "sec $s TOOL-FAIL"; rm -f "$gi.clean" "$gb.clean"; return 1; }
  kept=$(wc -l < "$gi.clean")
  if [ "$kept" -le 0 ] || [ "$kept" -ge "$orig" ]; then echo "sec $s ABORT orig=$orig kept=$kept"; rm -f "$gi.clean" "$gb.clean"; return 1; fi
  mv "$gi" "$gi.old" && mv "$gb" "$gb.old" && mv "$gi.clean" "$gi" && mv "$gb.clean" "$gb" && rm -f "$gi.old" "$gb.old"
  touch "$gi.fixed"
  echo "sec $s: orig=$orig kept=$kept dropped=$((orig-kept)) $(date)"
}
export -f fixone
seq 0 127 | xargs -P "$P" -I{} bash -c 'fixone "$@"' _ {} | tee -a "$LOG"
echo "=== fixGenLayerPar $T COMPLETE $(date) ===" | tee -a "$LOG"
