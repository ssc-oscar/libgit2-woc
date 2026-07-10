#!/bin/bash
# mkNewObjList.sh -- per-version "new objects" quick reference for the LAYERED object DB.
#
# The store is append-only per version across one layered id space (base ids
# 0..baseN-1, then gen ids baseN..baseN+genN-1). So the objects added in version
# $V are exactly the records past version $pV's per-section watermark:
#     base tail (records with id > nn(pV))   UNION   all of the gen (${t}_gen1)
# Purely POSITIONAL -- no sort, no set-difference against the prior universe.
#
# Two subcommands (run ONCE PER VERSION to keep the quick reference current):
#   record  <type> <V>                        -> $UD/All.<type>.<V> : 128 layered watermarks
#                                                (line = globalId;globalOff;len;sha of last layered record)
#   newlist <type> <pV> <V> <outdir> [secs..] -> $outdir/<pV><V>.<N>.cs : new-object sha list / section
#
# Env (da5 defaults): BASE=/da5_data/All.blobs  GENROOT=/fast/All.blobsGen  UD=/data/home/audris/update
# Notes: base-tail and gen are NOT disjoint for the irregular V2604->V2605 transition -- ~734M
#        commits bled into the FROZEN BASE *and* are also in commit_gen1 (verified: sec0 base-tail
#        5,739,948 shares 5,691,091 with the gen). So the union MUST be de-duped (LC_ALL=C sort -u);
#        a blind concat double-counts. The true new set = dedup(base-tail UNION gen). If a type has
#        no gen yet (e.g. blob pre-append) the gen half is skipped and it's base-tail only.
set -eu
BASE=${BASE:-/da5_data/All.blobs}
GENROOT=${GENROOT:-/fast/All.blobsGen}
UD=${UD:-/data/home/audris/update}

last_layered() {   # $1=type $2=section -> "globalId;globalOff;len;sha" of the last layered record
  local t=$1 o=$2 bl gl bid boff blen bcount bbytes gid goff glen gsha gidx
  bl=$(tail -1 "$BASE/${t}_$o.idx"); IFS=';' read -r bid boff blen _ <<<"$bl"
  bcount=$((bid+1)); bbytes=$((boff+blen))
  gidx="$GENROOT/${t}_gen1/${t}_$o.idx"
  if [ -s "$gidx" ]; then
    gl=$(tail -1 "$gidx"); IFS=';' read -r gid goff glen gsha <<<"$gl"
    echo "$((bcount+gid));$((bbytes+goff));$glen;$gsha"
  else
    echo "$bid;$boff;$blen;$(echo "$bl" | cut -d';' -f4)"
  fi
}

cmd=${1:?usage: record <type> <V> | newlist <type> <pV> <V> <outdir> [secs..]}; shift
case "$cmd" in
  record)
    t=${1:?type}; V=${2:?version}; out="$UD/All.$t.$V"
    [ -f "$out" ] && cp -a "$out" "$out.bak"      # preserve any prior snapshot
    : > "$out.tmp"
    for o in $(seq 0 127); do last_layered "$t" "$o" >> "$out.tmp"; done
    mv "$out.tmp" "$out"
    echo "recorded $out ($(wc -l <"$out") sections); sec0=$(head -1 "$out")"
    ;;
  newlist)
    t=${1:?type}; pV=${2:?prevVer}; V=${3:?curVer}; outdir=${4:?outdir}; shift 4
    secs="${*:-$(seq 0 127)}"
    wm="$UD/All.$t.$pV"; [ -s "$wm" ] || { echo "missing prior watermark $wm" >&2; exit 2; }
    mkdir -p "$outdir"
    for o in $secs; do
      nnpV=$(sed -n "$((o+1))p" "$wm" | cut -d';' -f1)
      out="$outdir/${pV}${V}.$o.cs"; gidx="$GENROOT/${t}_gen1/${t}_$o.idx"   # .cs = gzip, DEDUPED + SORTED
      # SORTED output (LC_ALL=C sort -u): dedups the base-tail/gen overlap AND leaves the .cs
      # sorted by sha so the downstream merge-sort (diff join) works. Do NOT reorder to positional.
      { tail -n +$((nnpV+2)) "$BASE/${t}_$o.idx" | cut -d';' -f4
        [ -s "$gidx" ] && cut -d';' -f4 "$gidx"; } | LC_ALL=C sort -u -S4G | gzip > "$out.tmp" && mv "$out.tmp" "$out"
      echo "$out: $(zcat "$out" | wc -l) new $t (nn($pV)=$nnpV, sorted+deduped union base-tail+gen)"
    done
    ;;
  *) echo "usage: $0 record <type> <V> | newlist <type> <pV> <V> <outdir> [secs..]" >&2; exit 1;;
esac
