#!/bin/bash
# backfillList.sh <bare-repo> [repo-name]
#
# Emit 'repo;blob;oid;' for every blob referenced by the repo's trees but ABSENT
# locally -- i.e. the exact phase-2 blob backfill set for a phase-1 partial fetch
# done with `--filter blob:none` (commits+trees, no blobs).
#
# After blob:none, all commits and trees are present, so the only reachable
# objects MISSING from the partial repo are blobs; `rev-list --missing=print`
# walks the present trees and prints those absent blob OIDs as '?<oid>'.
# Read-only; GIT_NO_LAZY_FETCH guarantees it never tries to download anything
# (important for promisor partial clones of new repos).
#
# Output (one per line, format-compatible with cleanBlb/hasObj):  repo;blob;oid;
set -u
repo=${1:?usage: backfillList.sh <bare-repo> [repo-name]}
name=${2:-$(basename "$repo")}
export GIT_NO_LAZY_FETCH=1
git --git-dir="$repo" rev-list --objects --all --missing=print 2>/dev/null \
  | awk -v R="$name" '/^\?/{print R";blob;"substr($1,2)";"}'
