#!/bin/bash
# doOtrVerFetch.sh <k> <ver> <DT>     e.g.  doOtrVerFetch.sh 050 V2605 202605
#
# Fetch-aware variant of doOtrVer.sh. Behaves identically (full `git clone
# --mirror`) for every project, EXCEPT projects that already have WoC tips: for
# those it does an incremental PARTIAL fetch (only the objects beyond the tips)
# via fetchNew.py instead of a full mirror clone.
#
# Reads two line-aligned files in <ver>.<k> (same order):
#   list<DT>.<ver>.<k>   the project list      (gh:Owner/Repo ...)
#   tips<DT>.<ver>.<k>   per-line WoC tips      (comma-sep commit SHAs, EMPTY=new)
# (the tips file is produced by mkTipsFiles.sh).
#
# Partial repos get packed-refs written (fetchNew --write-refs) so the listing
# step and gitListSimp.sh (`rev-list --objects --all --missing=allow-any`) pick
# them up exactly like a full mirror. Lifecycle marker unchanged:
#   cloning -> listed -> grabbing -> rsynced -> verified
k=$1; ver=$2; DT=$3
dir=$ver.$k
pre=list$DT.$ver
tpre=tips$DT.$ver
cd "$dir" || exit 1
echo "cloning $(date '+%F %T')" > STAGE
export ver pre

# TokyoCabinet etc. live in /usr/local/lib; make sure children can load them.
export LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

# Optional partial-clone filter (phase-1 of deferred-blob extraction). Empty by
# default => unchanged full-object behavior. Set e.g. FILTER=blob:none to fetch
# only commits+trees now and defer blobs (see fetchExoP1.sh / backfillExo.sh).
# Most valuable on the tips (updated-repo) branch: haves + blob:none = only the
# new commits/trees beyond WoC, no blobs.
FILTER=${FILTER:-}

do_one(){
  local i=$1 t=$2 j r url
  j=$(printf '%s' "$i" | perl -ane 's|^gh:([^/]+)/|$1_|;s|^bb:([^/]+)/|bitbucket.org_$1_|;s|^gl:([^/]+)/|gitlab.com_$1_|;s|^dr:([^/]+)/|drupal.com_$1_|;s|^https://([^/]*)/([^/]*)/|$1_$2_|;s|^https://([^/]*)/|$1_|;print')
  [ -z "$j" ] && return
  mkdir "$j" 2>/dev/null || return          # atomic claim; already present/in-progress -> skip
  if [ -n "$t" ]; then
    # incremental partial fetch: only objects beyond the WoC tips (haves)
    url=$(printf '%s' "$i" | perl -ane 's|^gh:|https://github.com/|;s|^bb:|https://bitbucket.org/|;s|^gl:|https://gitlab.com/|;s|^dr:|https://drupal.com/|;print')
    if ! python3 "$HOME/bin/fetchNew.py" "$url" --haves "$t" --write-refs ${FILTER:+--filter "$FILTER"} --out "$j" >/dev/null 2>>fetch.err; then
      # partial fetch failed (e.g. server sent a thin pack despite no-thin -> unresolved
      # deltas, or repo gone). Fall back to a full mirror clone: self-contained, and
      # runExo's hasObj dedups the redundancy. (Gone repos fail the clone too -> absent.)
      echo "FETCHFAIL $i" >> fetch.err; rm -rf "$j"
      r=$(printf '%s' "$i" | sed 's|^https://|https://a:a@|;s|^https://a:a@git.launchpad.net/|lp:|')
      git clone ${FILTER:+--filter="$FILTER"} --mirror "$r" "$j" 2>>clone.err
    fi
  else
    # new project (no tips) -> full mirror clone, exactly like doOtrVer.sh
    r=$(printf '%s' "$i" | sed 's|^https://|https://a:a@|;s|^https://a:a@git.launchpad.net/|lp:|')
    rmdir "$j" 2>/dev/null                   # let git clone create it
    git clone ${FILTER:+--filter="$FILTER"} --mirror "$r" "$j" 2>>clone.err
  fi
}
export -f do_one

# line-aligned (list ; tips), a:a@ stripped from the list like doOtrVer.sh
paste -d$'\t' <(sed 's|a:a@||' "$pre.$k") "$tpre.$k" > .lt.$k
# 4 workers (2 forward, 2 reverse from the other end) for parallelism + resume
for pass in 1 2; do
  ( while IFS=$'\t' read -r i t; do do_one "$i" "$t"; done < .lt.$k ) &
  ( tac .lt.$k | while IFS=$'\t' read -r i t; do do_one "$i" "$t"; done ) &
done
wait
rm -f .lt.$k

# present repo dirs (mangled names that exist) -> ${pre}1.$k  (same as doOtrVer.sh)
cat "$pre.$k" | sed 's|a:a@||' | while read i;
do r=$(printf '%s' "$i" | perl -ane 's|^gh:([^/]+)/|$1_|;s|^bb:([^/]+)/|bitbucket.org_$1_|;s|^gl:([^/]+)/|gitlab.com_$1_|;s|^dr:([^/]+)/|drupal.com_$1_|;s|^https://([^/]*)/([^/]*)/|$1_$2_|;s|^https://([^/]*)/|$1_|;print');
  [[ -d $r ]] && echo $r; done > "${pre}1.$k"

echo "listing $(date '+%F %T')" > STAGE
cat "${pre}1.$k" | while read i; do [[ -f $i/packed-refs ]] && echo $i/packed-refs; done | cpio -o | gzip > "../${pre}.$k.cpio.gz"
# clone/list stage complete -> runExo.sh may proceed
echo "listed $(date '+%F %T')" > STAGE
