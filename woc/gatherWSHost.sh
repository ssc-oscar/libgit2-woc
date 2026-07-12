#!/bin/bash
# gatherWSHost.sh -- drive gatherWS over all 128 closure shards to build the SSD
# working-set store for the fast cmputeDiffGen pass. RUN ON da5 (tree store local).
#
# Input : isaac's closure shards `closure.<sec>.gz` (bare tree-sha, byte-sharded) — via the
#         da8 mount on da5 (`/da8_data/update/V2605d/`) per `coord/isaac/closure-status.md`.
# Output: gen-shaped WS store `$WS/tree_gen1/tree_<sec>.{bin,sidx}` on fast storage; the diff
#         runs with LAYERED=$WS (SSD) + base as residual fallback. rclone $WS to clone0 SSD if
#         the diff runs there.
#
# Resumable (per-sec .done), P-parallel. The per-sec gather reads the HDD store in OFFSET
# ORDER (one sequential sweep), so P should stay modest (I/O, not CPU) — a few streams saturate
# sequential bandwidth; too many reintroduce seeks.
set -u
CLOSURE_DIR=${CLOSURE_DIR:-/da8_data/update/V2605d}          # closure.<sec>.gz live here (da8 mount)
WS=${WS:-/fast/All.blobsWS/V2605}
BIN=${BIN:-/da5_fast/bin/gatherWS}
TMP=${TMP:-/tmp/closure}; mkdir -p "$TMP" "$WS/tree_gen1"
PAR=${PAR:-6}
export WS BIN TMP
export LD_LIBRARY_PATH=/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export PREO=${PREO:-/fast/All.sha1o} BASEBIN=${BASEBIN:-/data/All.blobs} LAYERED=${LAYERED:-/fast/All.blobsGen}
export VERIFY=${VERIFY:-}
echo "=== gatherWSHost P=$PAR closure=$CLOSURE_DIR ws=$WS $(date -u) ==="
one(){
  s=$1
  [ -f "$WS/.done.$s" ] && { echo "sec $s already done"; return 0; }
  f="$TMP/closure.$s"
  if [ ! -s "$f" ]; then
    if   [ -s "$CLOSURE_DIR/closure.$s.gz" ]; then zcat "$CLOSURE_DIR/closure.$s.gz" > "$f"
    elif [ -s "$CLOSURE_DIR/closure.$s" ];    then cp "$CLOSURE_DIR/closure.$s" "$f"
    else echo "sec $s: no closure input in $CLOSURE_DIR"; return 0; fi
  fi
  if VERIFY="$VERIFY" "$BIN" "$f" "$WS" "$s"; then
    touch "$WS/.done.$s"; rm -f "$f"
    echo "sec $s DONE: $(( $(stat -c%s "$WS/tree_gen1/tree_$s.sidx" 2>/dev/null||echo 0)/32 )) trees, bin=$(stat -c%s "$WS/tree_gen1/tree_$s.bin" 2>/dev/null||echo 0)B"
  else echo "sec $s FAILED"; fi
}
export -f one
seq 0 127 | xargs -P"$PAR" -I{} bash -c 'one "$@"' _ {}
tot=$(cat "$WS"/tree_gen1/*.sidx 2>/dev/null | wc -c); echo "=== WS COMPLETE $(date -u): $(ls "$WS"/.done.* 2>/dev/null|wc -l)/128 secs, $((tot/32)) trees, $(du -sh "$WS" 2>/dev/null|cut -f1) ==="
