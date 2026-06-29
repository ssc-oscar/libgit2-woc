#!/bin/bash
# pickdisk.sh [vol1 vol2 ...]  -- echo the grab output volume name with the MOST
# free bytes (default candidates: b out). Replaces the old static odd->out/even->b
# parity interleave with dynamic free-space balancing. Picking max-free inherently
# avoids the fuller disk, so it subsumes the previous ">=97% full" fallback guard.
set -u
cands=("$@"); [ ${#cands[@]} -eq 0 ] && cands=(b out)
best=""; bestfree=-1
for v in "${cands[@]}"; do
  f=$(df -B1 --output=avail "/media/volume/$v" 2>/dev/null | tail -1 | tr -dc 0-9)
  [ -z "$f" ] && continue
  if [ "$f" -gt "$bestfree" ]; then bestfree=$f; best=$v; fi
done
echo "${best:-out}"
