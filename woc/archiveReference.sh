#!/bin/bash
# Seed the da8 reference archive from local bare clones (avoids re-downloading repos
# already cloned during a grab). Reference-class repos (curated security/vuln/threat
# catalogues, listed in $REFERENCE_FILE) are NOT extracted into WoC -- runExo skips
# all their object types -- so their intact clone is preserved on da8 instead, where
# it stays usable as the dataset. Ongoing freshness: refreshReference.sh (cron).
#   Usage: archiveReference.sh [<dir>...]   default: scan all chunk dirs under $TREES
set -u
: "${VOL:=/media/volume}"; : "${TREES:=$VOL/trees}"
: "${REFERENCE_FILE:=$TREES/reference}"
: "${REF_DEST:=da8:/mnt/ordos/data/data/reference}"   # <owner_repo>.git/ archives
: "${REF_MANIFEST:=$TREES/reference.manifest}"
[ -s "$REFERENCE_FILE" ] || { echo "[archiveRef] no reference list $REFERENCE_FILE"; exit 0; }
host=${REF_DEST%%:*}; path=${REF_DEST#*:}
ssh "$host" "mkdir -p '$path'" 2>/dev/null
touch "$REF_MANIFEST"
roots=("$@"); [ ${#roots[@]} -eq 0 ] && roots=("$TREES"/*/)
grep -v '^[[:space:]]*#' "$REFERENCE_FILE" | cut -d';' -f1 | grep . | while read -r r; do
  src=""
  for root in "${roots[@]}"; do [ -d "$root/$r" ] && { src="$root/$r"; break; }; done
  if [ -z "$src" ]; then echo "[archiveRef] $r: no local clone -> leave to refreshReference.sh (da8 fetch)"; continue; fi
  owner=${r%%_*}; repo=${r#*_}; url="https://github.com/$owner/$repo"
  echo "[archiveRef] $r <- $src -> $REF_DEST/$r.git"
  if rsync -a --delete "$src/" "$REF_DEST/$r.git/"; then
    sz=$(du -sb "$src" 2>/dev/null | cut -f1); head=$(git --git-dir="$src" rev-parse HEAD 2>/dev/null)
    grep -v "^$r;" "$REF_MANIFEST" > "$REF_MANIFEST.t" 2>/dev/null; mv -f "$REF_MANIFEST.t" "$REF_MANIFEST"
    printf '%s;%s;%sB;%s;seeded %s\n' "$r" "$url" "${sz:-?}" "${head:-nohead}" "$(date +%F)" >> "$REF_MANIFEST"
  else echo "[archiveRef] WARN rsync failed for $r" >&2; fi
done
echo "[archiveRef] done -> manifest $REF_MANIFEST"
