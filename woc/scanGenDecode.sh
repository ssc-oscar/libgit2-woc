#!/bin/bash
# scanGenDecode.sh [type] [PAR]   (da5) -- scan the ENTIRE gen sidx for records that won't decode,
# producing the exact re-grab set of corrupt gen objects. Runs getObjGen SCAN per section in parallel.
# type = commit (default) | tree. Output: gen_decodefail.<type>.tsv.gz  (lines: <decodefail|readfail>\t<sec>\t<sha>)
# + a per-sec summary on the .log. Read-only; safe alongside the store.
set -u
TYPE=${1:-commit}; PAR=${2:-16}
BIN=${BIN:-$HOME/bin/getObjGen}
CONTENT=${CONTENT:-/fast/All.sha1c}; OFFT=${OFFT:-/fast/All.sha1o}; BASEBIN=${BASEBIN:-/data/All.blobs}
export LAYERED=${LAYERED:-/fast/All.blobsGen}
OUT=${OUT:-$HOME/gen_decodefail.$TYPE.tsv}; LOG=$OUT.log
: > "$OUT.tmp"; : > "$LOG"
echo "[scanGenDecode] type=$TYPE par=$PAR $(date -u)" | tee -a "$LOG"
scan_one(){ s=$1
  SCAN=1 SEC=$s LAYERED="$LAYERED" "$BIN" "$TYPE" "$CONTENT" "$OFFT" "$BASEBIN" \
    >> "$OUT.tmp" 2>> "$LOG"
}
export -f scan_one; export BIN TYPE CONTENT OFFT BASEBIN LAYERED OUT LOG
seq 0 127 | xargs -P"$PAR" -I{} bash -c 'scan_one "$@"' _ {}
LC_ALL=C sort "$OUT.tmp" | gzip > "$OUT.gz"; rm -f "$OUT.tmp"
nd=$(zcat "$OUT.gz" | grep -c '^decodefail'); nr=$(zcat "$OUT.gz" | grep -c '^readfail')
echo "[scanGenDecode] DONE $(date -u): $nd decodefail + $nr readfail -> $OUT.gz" | tee -a "$LOG"
