#!/bin/bash
# fetchExoSeq.sh <m> <ver> <DT> [out]
# Like fetchExo.sh (clone via doOtrVerFetch, then extract), but uses runExoSeq.sh so the
# grab is SEQUENTIAL one shard at a time with deoff+drain between shards -- for the heavy
# 137+ ROOTS series, to bound peak disk (the all-parallel runExo filled b on 140).
set -u
m=${1:?usage: fetchExoSeq.sh <m> <ver> <DT> [out]}; ver=${2:?}; DT=${3:?}; out=${4:-out}
cd "${TREES:-/media/volume/trees}" || { echo "[fetchExoSeq $ver.$m] cannot cd to trees root"; exit 1; }
S="/media/volume/trees/$ver.$m/STAGE"
/home/exouser/bin/genOffenderFilter.sh >/dev/null 2>&1 || true
echo "[fetchExoSeq $ver.$m] clone/fetch start $(date '+%F %T')"
/home/exouser/bin/doOtrVerFetch.sh "$m" "$ver" "$DT" || { echo "[fetchExoSeq $ver.$m] doOtrVerFetch FAILED $(date '+%F %T')"; exit 1; }
echo "[fetchExoSeq $ver.$m] listed $(date '+%F %T'); SEQUENTIAL extract start"
/home/exouser/bin/runExoSeq.sh "$m" "$ver" "$out" || { echo "[fetchExoSeq $ver.$m] runExoSeq FAILED $(date '+%F %T')"; exit 1; }
echo "[fetchExoSeq $ver.$m] DONE $(date '+%F %T'): STAGE=$(cat "$S" 2>/dev/null)"
