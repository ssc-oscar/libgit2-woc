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
OUT="$TREES/dropcommitTips.$VER.gz"       # gzipped: isaac's mkTipsFiles reader pipes through pigz -dc
OLD="$TREES/dropcommitTips.$VER"          # legacy plain (mangled-key) capture, if present
tmp=$(mktemp "${TMPDIR:-/tmp}/dctips.XXXXXX")
# seed from existing (accumulate). tmp holds MANGLED owner_repo keys internally (dir-lookup + the
# idempotent dedup below both key on the mangled name); the final write normalizes to the p2tips
# key (owner/repo) and gzips.
if   [ -f "$OUT" ]; then zcat "$OUT" | sed 's,/,_,' > "$tmp"   # normalized gz -> back to mangled
elif [ -f "$OLD" ]; then cp -a "$OLD" "$tmp"; fi              # legacy plain already mangled
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
# normalize mangled owner_repo -> p2tips key owner/repo (first '_' -> '/'; GitHub owner has no '_'),
# then sort by the normalized key and gzip (isaac's mkTipsFiles streams it via pigz -dc as a
# --haves shard: P2tips U dropcommitTips). Sort AFTER normalize so order matches the p2tips keyspace.
LC_ALL=C sed 's,_,/,' "$tmp" | LC_ALL=C sort -u | gzip -9 > "$OUT"; rm -f "$tmp"
echo "captureDropcommitTips $VER: $(zcat "$OUT" | wc -l) total tip lines, $captured newly captured"
[ -n "$gone" ] && echo "  CLONE GONE (tips NOT capturable here -- recover from da8/GitHub):$gone"
