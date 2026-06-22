#!/bin/bash
# detectOffenders.sh [--add] [--thresh PCT] <olist-dir> [<olist-dir> ...]
#
# Proactive offender detection from the size-split olist chunks. The grab splits a
# dataset's filtered object enumeration into 16 EQUAL-SIZE chunks
# (New<DT><VER>.<NNN>.olist.<SS>.gz). A normal chunk draws from thousands of repos;
# a chunk dominated by a SINGLE repo (distinct==1, or top repo >= THRESH%) means that
# repo is offender-sized (a data dump / giant fork) and will wedge / bloat the grab.
# This flags such repos BEFORE the dump, so they can be added to the offenders
# registry (-> woc.pm largeBlobPrj/largeTreePrj -> grab-time blob:none/tree:0).
#
#   detectOffenders.sh /media/volume/out/V2605.118            # scan one dataset's chunks
#   detectOffenders.sh --add /media/volume/{out,b}/V2605.*    # scan + append NEW candidates
#
#   --thresh PCT : dominance threshold (default 90). distinct==1 always qualifies.
#   --add        : append NEW (not-yet-listed) candidates to OFFENDERS registry.
# Env: OFFENDERS (default /media/volume/trees/offenders).
set -u
THRESH=90; ADD=0; OFFENDERS=${OFFENDERS:-/media/volume/trees/offenders}
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --add) ADD=1; shift;;
    --thresh) THRESH=$2; shift 2;;
    *) args+=("$1"); shift;;
  esac
done
[ ${#args[@]} -ge 1 ] || { echo "usage: detectOffenders.sh [--add] [--thresh PCT] <olist-dir>..."; exit 2; }
known=$(cut -d';' -f1 "$OFFENDERS" 2>/dev/null | sort -u)
tmpnew=$(mktemp)

for d in "${args[@]}"; do
  for o in "$d"/New*.olist.*.gz; do
    [ -f "$o" ] || continue
    read tot dist top rep < <(zcat "$o" 2>/dev/null | awk -F';' '
      {c[$1]++; n++} END{ mx=0; t=""; for(r in c) if(c[r]>mx){mx=c[r]; t=r}
        printf "%d %d %.1f %s", n, length(c), (n?100*mx/n:0), t }')
    [ -z "${rep:-}" ] && continue
    qualifies=0
    [ "$dist" = 1 ] && qualifies=1
    awk "BEGIN{exit !($top >= $THRESH)}" && qualifies=1
    [ "$qualifies" = 1 ] || continue
    flag=NEW; grep -Fxq "$rep" <<<"$known" && flag=LISTED
    printf "%s\tdistinct=%s\ttop=%s%%\t%s\t[%s]\n" "$(basename "$o")" "$dist" "$top" "$rep" "$flag"
    [ "$flag" = NEW ] && echo "$rep" >> "$tmpnew"
  done
done

newu=$(sort -u "$tmpnew")
n=$(grep -c . <<<"$newu" 2>/dev/null); [ -z "$newu" ] && n=0
echo "--- $n NEW offender candidate repo(s) ---"
[ -n "$newu" ] && echo "$newu"
if [ "$ADD" = 1 ] && [ -n "$newu" ]; then
  while read -r r; do
    [ -n "$r" ] && ! grep -q "^${r};" "$OFFENDERS" && \
      printf '%s;single-repo-olist-chunk;detected %s;auto-detected offender (detectOffenders.sh)\n' "$r" "$(date +%F)" >> "$OFFENDERS"
  done <<<"$newu"
  echo "appended $n new offender(s) to $OFFENDERS (regenerate skip lists + commit)"
fi
rm -f "$tmpnew"
