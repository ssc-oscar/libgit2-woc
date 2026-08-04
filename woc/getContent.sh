#!/bin/bash
# getContent.sh <type> [-r]   (da5) -- GEN-AWARE showCnt: read `sha[;rest]` from STDIN, print the object
# content from base UNION gen. Unlike showCnt.perl (base-only, silently misses gen objects), this resolves
# the gen layer too. <type> = commit | tree | blob | tag | tkns.
#   default        : one line per sha  ->  <sha>;<base64(content)>   (SAFE for binary/multiline blobs)
#   -r / RAW=1     : raw object bytes to stdout, no framing (single object, cat-style)
# da5 default paths baked in (override via env PREC/PREO/BASEBIN/LAYERED/BIN):
#   commit/tag/tkns content in /fast/All.sha1c ; tree/blob offset in /fast/All.sha1o -> /data/All.blobs bins ;
#   gen in /fast/All.blobsGen. (blob base CONTENT is not on da5 -> blob resolves only from gen here.)
set -u
TYPE=${1:?usage: getContent.sh <commit|tree|blob|tag|tkns> [-r] < shas}; shift || true
[ "${1:-}" = "-r" ] && { export ENC=raw; shift || true; }
BIN=${BIN:-$HOME/bin/getObjGen}
PREC=${PREC:-/fast/All.sha1c}                       # commit/tag/tkns CONTENT .tch
PREO=${PREO:-/fast/All.sha1o}                       # tree/blob OFFSET .tch
BASEBIN=${BASEBIN:-/data/All.blobs}                 # base content bins (tree real; blob stub on da5)
export LAYERED=${LAYERED:-/fast/All.blobsGen}       # gen layer
exec "$BIN" "$TYPE" "$PREC" "$PREO" "$BASEBIN"
