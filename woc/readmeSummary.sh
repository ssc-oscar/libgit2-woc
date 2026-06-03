#!/bin/bash
# Print a one-line summary (first 1000 bytes, whitespace-collapsed, <=300 chars)
# of a bare repo's top-level README; fall back to CLAUDE.md; else a placeholder.
#   readmeSummary.sh /media/volume/trees/V2605.030/owner_repo
gd=$1
[[ -d $gd ]] || { echo "(repo gone)"; exit 0; }
f=$(git --git-dir="$gd" ls-tree --name-only HEAD 2>/dev/null | grep -iE '^(readme|claude\.md)' | head -1)
[[ -z $f ]] && { echo "(no README/CLAUDE.md)"; exit 0; }
git --git-dir="$gd" show "HEAD:$f" 2>/dev/null \
  | head -c 1000 | tr '\n\r\t;' '    ' | tr -s ' ' | cut -c1-300
