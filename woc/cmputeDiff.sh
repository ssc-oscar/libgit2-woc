#!/bin/bash
# cmputeDiff.sh [sha ...]   (run on da5) -- logical (file-level) diff of commit(s) via the store-resident
# cmputeDiffGenFB, with the correct da5 default paths baked in. Reads commit shas from ARGS or STDIN.
#
# Output (one row per changed file, ';'-separated):
#     <commit> ; <new_path> ; <new_blob_sha> ; <old_path>
#   - empty <old_path>  => file ADDED (new blob, no predecessor)
#   - <new_path> != <old_path> => rename/move (content bumped between paths)
#   - a deleted file shows as a row with the old side populated / new blob absent
#
# Resolves objects from the base store (commit+tree CONTENT .tch, blob offset) UNION the gen layer, so it
# works for ANY commit whose objects are in the store -- BF-closure membership is irrelevant (the closure
# is only the pre-staged fast subset; this reads the full store). If a commit's objects aren't in the
# store it prints "no commit <sha> / commit=0" (fetch it first).
#
# KEY: <contentDir> is /fast/All.sha1c -- commits & trees are CONTENT .tch there. NOT /fast/All.sha1o,
# which is the BLOB-offset store only (using it as contentDir makes every commit lookup miss -> commit=0).
#
# Override any path via env: BIN CONTENT OFFT BASEBIN LAYERED
set -u
BIN=${BIN:-$HOME/bin/cmputeDiffGenFB}
CONTENT=${CONTENT:-/fast/All.sha1c}                 # base commit + tree CONTENT .tch (primary source)
OFFT=${OFFT:-/fast/All.sha1o}                       # blob offset store (its presence sets HAVEFB=1 fallback)
BASEBIN=${BASEBIN:-/data/All.blobs}                 # base content segments
export LAYERED=${LAYERED:-/fast/All.blobsGen}       # gen layer (sidx) -> gen-resident trees

{ [ "$#" -gt 0 ] && printf '%s\n' "$@" || cat; } | "$BIN" "$CONTENT" "$OFFT" "$BASEBIN"
