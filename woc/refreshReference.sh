#!/bin/bash
# Refresh the da8 reference archive: da8 has GitHub egress and 200T+ free, so all
# git/network work happens THERE (no staging on the space-pressured trees volume).
# For each reference repo: clone --mirror if missing, else `git remote update --prune`.
# Run from cron on clone0 (e.g. weekly); keeps the curated catalogues current.
#   Usage: refreshReference.sh
set -u
: "${VOL:=/media/volume}"; : "${TREES:=$VOL/trees}"
: "${REFERENCE_FILE:=$TREES/reference}"
: "${REF_DEST:=da8:/mnt/ordos/data/data/reference}"
: "${REF_MANIFEST:=$TREES/reference.manifest}"
[ -s "$REFERENCE_FILE" ] || exit 0
host=${REF_DEST%%:*}; path=${REF_DEST#*:}
touch "$REF_MANIFEST"
mapfile -t REFS < <(grep -v '^[[:space:]]*#' "$REFERENCE_FILE" | cut -d';' -f1 | grep .)
for r in "${REFS[@]}"; do
  owner=${r%%_*}; repo=${r#*_}; url="https://github.com/$owner/$repo"
  res=$(ssh -n "$host" "d='$path/$r.git'
    if [ -d \"\$d\" ]; then git --git-dir=\"\$d\" remote update --prune >/dev/null 2>&1 || exit 3
    else git clone --mirror '$url' \"\$d\" >/dev/null 2>&1 || exit 4; fi
    printf '%s %s' \"\$(git --git-dir=\"\$d\" rev-parse HEAD 2>/dev/null)\" \"\$(du -sb \"\$d\" 2>/dev/null | cut -f1)\"" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then echo "[refreshRef] FAIL $r (rc=$rc, $url)" >&2; continue; fi
  head=${res%% *}; sz=${res##* }
  grep -v "^$r;" "$REF_MANIFEST" > "$REF_MANIFEST.t" 2>/dev/null; mv -f "$REF_MANIFEST.t" "$REF_MANIFEST"
  printf '%s;%s;%sB;%s;refreshed %s\n' "$r" "$url" "${sz:-?}" "${head:-nohead}" "$(date +%F)" >> "$REF_MANIFEST"
  echo "[refreshRef] $r OK ($head)"
done
echo "[refreshRef] done $(date '+%F %T')"
