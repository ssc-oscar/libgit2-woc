#!/bin/bash
# captureDropcommitTips.sh [VER]
#
# Capture the TIP commits (branch/tag heads) of dropcommit "total-offender" repos
# (commit-bombs: offenders + dropcommit, commits dropped from WoC) so they can be
# added to the fetch `--haves` set for FUTURE versions -- avoiding a full re-download
# of the spam history every cycle -- WITHOUT storing the commits in WoC (P2c/c2p/gen
# stay excluded via the dropcommit list). The two sets differ:
#   stored/analyzed  = everything EXCEPT dropcommit commits
#   fetch --haves    = every tip we've ever seen, INCLUDING dropcommit repos
#
# MUST run while the clone is still present (before verified-clone deletion). Rare
# (dropcommit repos are few), so cheap to run periodically + right after registering
# a new commit-bomb. Appends repo;tip_commit_sha to $OUT (dedup on merge), drained to da8.
set -u
VER="${1:-V2605}"
DC=/media/volume/trees/dropcommit
TREES=/media/volume/trees
OUT="$TREES/dropcommitTips.$VER"
tmp=$(mktemp "${TMPDIR:-/tmp}/dctips.XXXXXX")
[ -f "$OUT" ] && cp -a "$OUT" "$tmp"   # start from existing (accumulate)
captured=0; gone=""
for repo in $(grep -vE '^#|^$' "$DC" 2>/dev/null | cut -d';' -f1); do
  # already have tips for it? skip (idempotent)
  grep -q "^$repo;" "$tmp" 2>/dev/null && continue
  d=$(ls -d "$TREES"/$VER.*/"$repo" 2>/dev/null | head -1)
  if [ -n "$d" ] && [ -d "$d" ]; then
    # ref heads, peeled to the underlying commit for annotated tags -> the true tips
    git --git-dir="$d" for-each-ref \
        --format='%(if)%(*objectname)%(then)%(*objectname)%(else)%(objectname)%(end)' 2>/dev/null \
      | sort -u | while read -r sha; do [ -n "$sha" ] && echo "$repo;$sha"; done >> "$tmp"
    captured=$((captured+1))
    echo "  captured tips: $repo ($(grep -c "^$repo;" "$tmp") tips) from $d"
  else
    gone="$gone $repo"
  fi
done
LC_ALL=C sort -u "$tmp" > "$OUT"; rm -f "$tmp"
echo "captureDropcommitTips $VER: $(wc -l < "$OUT") total tip lines, $captured newly captured"
[ -n "$gone" ] && echo "  CLONE GONE (tips NOT capturable here -- recover from da8/GitHub):$gone"
