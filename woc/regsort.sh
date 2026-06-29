#!/bin/bash
# regsort.sh <file>  -- sort -u a registry file (offenders/keep/reference/...) ATOMICALLY.
# `sort -u -o f f` opens the OUTPUT first and TRUNCATES it, so a concurrent reader
# (deoffdrainP/deOffend building its offender set) can observe an EMPTY file and wrongly
# conclude "no offenders" -> drain a raw shard. Writing to a temp and renaming (mv) is
# atomic: readers always see the complete old file or the complete new file, never empty.
# Usage: append with `echo entry >> offenders` (atomic for a single short line), then
#        `regsort.sh offenders` to dedup/sort safely.
set -u
f="${1:?usage: regsort.sh <registry-file>}"
[ -f "$f" ] || { echo "regsort: no such file: $f" >&2; exit 1; }
t=$(mktemp "$(dirname "$f")/.$(basename "$f").XXXXXX") || exit 1
if LC_ALL=C sort -u "$f" > "$t"; then mv -f "$t" "$f"; else rm -f "$t"; echo "regsort: sort failed" >&2; exit 1; fi
