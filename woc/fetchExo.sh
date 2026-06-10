#!/bin/bash
# fetchExo.sh <m> <ver> <DT> [out]
# Combined tips-fetch CLONE + EXTRACT for one dataset, in a single step:
#   1) doOtrVerFetch.sh -- partial fetch-by-tips for repos WoC already knows
#      (only objects beyond the tips), full `git clone --mirror` for the rest,
#      with full-clone fallback on fetch failure; sets STAGE listed.
#   2) runExo.sh -- cat-file --batch-all-objects enumerate (handles partial repos),
#      da5 cleanBlb|hasObj dedup, offenders blob-exclude, grabGitI dump, rsync to
#      da8, deOffend verify; sets STAGE rsynced->verified.
set -u
m=${1:?usage: fetchExo.sh <m> <ver> <DT> [out]}; ver=${2:?}; DT=${3:?}; out=${4:-out}
# doOtrVerFetch.sh and runExo.sh cd into "$ver.$m" relatively, so we must run
# from the trees root regardless of the caller's cwd.
cd "${TREES:-/media/volume/trees}" || { echo "[fetchExo $ver.$m] cannot cd to trees root"; exit 1; }
S="/media/volume/trees/$ver.$m/STAGE"
echo "[fetchExo $ver.$m] clone/fetch start $(date '+%F %T')"
/home/exouser/bin/doOtrVerFetch.sh "$m" "$ver" "$DT" || { echo "[fetchExo $ver.$m] doOtrVerFetch FAILED $(date '+%F %T')"; exit 1; }
echo "[fetchExo $ver.$m] listed $(date '+%F %T'); extract start"
/home/exouser/bin/runExo.sh "$m" "$ver" "$out" || { echo "[fetchExo $ver.$m] runExo FAILED $(date '+%F %T')"; exit 1; }
echo "[fetchExo $ver.$m] DONE $(date '+%F %T'): STAGE=$(cat "$S" 2>/dev/null)"
