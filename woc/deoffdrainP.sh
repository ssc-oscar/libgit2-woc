#!/bin/bash
# Generalized parallel deoff+drain for a list of COMPLETE shards.
#   deoffdrainP.sh VER "shard list..."
# Deoffs run back-to-back (filter-in-place, only if shard carries offenders);
# each shard's verify(checkBin1in)+drain to da8 is backgrounded so it never
# blocks the next deoff. Offender-free shards drain directly. Empty shards
# (0-byte blob) are shipped as stubs.
V="$1"; shift; shards="$*"
base=New202605V2605; dest=da8:/mnt/ordos/data/data/update/V2605/
d=""
for cand in /media/volume/b/V2605.$V /media/volume/out/V2605.$V; do
  [ -d "$cand" ] && { d="$cand"; break; }
done
[ -z "$d" ] && { echo "no dir for $V"; exit 1; }
cut -d';' -f1 /media/volume/trees/offenders | sort -u > /tmp/odp.$V
comm -23 /tmp/odp.$V <(sort -u /media/volume/trees/keep) > /tmp/odp.$V.2; mv /tmp/odp.$V.2 /tmp/odp.$V
# SAFETY: the offenders registry has tens of thousands of entries. An EMPTY read here
# means we caught the file mid-rewrite (truncation window of a non-atomic sort) -- if we
# proceed, every shard looks "clean" and we drain RAW offender data to da8. ABORT instead.
if [ ! -s /tmp/odp.$V ]; then echo "ABORT $V: offenders read EMPTY (registry truncated mid-rewrite?) -- NOT draining anything"; exit 1; fi

drainbg(){ local l=$1
  ( # RACE GUARD: re-check offenders against the LIVE registry right before draining
    # -- an offender may have been registered since deoffdrainP started; if so, do
    # NOT ship it un-deoffed. Skip; the next handler cycle re-reads + deoffs it.
    cut -d';' -f1 /media/volume/trees/offenders 2>/dev/null | sort -u > "/tmp/odp.$V.$l.live"
    comm -23 "/tmp/odp.$V.$l.live" <(sort -u /media/volume/trees/keep 2>/dev/null) > "/tmp/odp.$V.$l.live2"; mv "/tmp/odp.$V.$l.live2" "/tmp/odp.$V.$l.live"
    # SAFETY: empty live read = registry caught mid-rewrite -> do NOT drain (would ship raw).
    if [ ! -s "/tmp/odp.$V.$l.live" ]; then echo "  $V.$l: offenders read EMPTY -- NOT draining (retry next cycle)"; return; fi
    rb=$(awk -F';' 'NR==FNR{o[$1]=1;next} o[$5]{s+=$2}END{printf "%.3f",s/1e9}' "/tmp/odp.$V.$l.live" $d/$base.$V.$l.blob.idx 2>/dev/null)
    rt=$(awk -F';' 'NR==FNR{o[$1]=1;next} o[$5]{s+=$2}END{printf "%.3f",s/1e9}' "/tmp/odp.$V.$l.live" $d/$base.$V.$l.tree.idx 2>/dev/null)
    if ! awk "BEGIN{exit !(${rb:-0}==0 && ${rt:-0}==0)}"; then echo "  $V.$l became dirty (off blob=${rb}GB tree=${rt}GB) -- NOT draining, will deoff next cycle"; return; fi
    for t in blob tree; do
      [ -s "$d/$base.$V.$l.$t.bin" ] || continue
      err=$(perl -I /home/exouser/lib64/perl5 /home/exouser/lookup/checkBin1in.perl "$t" "$d/$base.$V.$l.$t" 2>&1 >/dev/null)
      [ -n "$err" ] && { echo "  $V.$l checkBin1in $t FAIL -- KEPT: $(echo "$err"|head -1)"; return; }
    done
    # include the RAW per-shard olist (NN.olist.gz) as provenance; NOT the deduped olist.NN.gz
    rawolist=""; [ -f "$d/$base.$V.$l.olist.gz" ] && rawolist="$d/$base.$V.$l.olist.gz"
    ionice -c3 rsync -a $d/$base.$V.$l.{blob,commit,tree,tag}.{bin,idx} $rawolist "$dest" 2>&1 | tail -1
    if [ "${PIPESTATUS[0]}" -eq 0 ]; then
      rm -f $d/$base.$V.$l.{blob,commit,tree,tag}.{bin,idx} $rawolist
      echo "  $V.$l DRAINED+removed (incl raw olist) $(date '+%T'); $(basename $d) free $(df -h $d|awk 'END{print $4}')"
    else echo "  $V.$l rsync FAILED -- KEPT"; fi ) &
}

for l in $shards; do
  [ -f "$d/$base.$V.$l.blob.bin" ] || { echo "## $V.$l absent -- skip"; continue; }
  # never touch a shard with a LIVE or SUSPENDED grabGitI (incomplete)
  if pgrep -f "grabGitI.*$base\.$V\.$l\$" >/dev/null 2>&1; then echo "## $V.$l has grabGitI (incomplete) -- SKIP"; continue; fi
  # never double-process a shard already being deoffed/drained (idempotent for repeated handler calls)
  if pgrep -f "rsync.*$base\.$V\.$l\.|filterDeoff.pl (blob|tree) [^ ]*$V\.$l$" >/dev/null 2>&1; then echo "## $V.$l already in deoff/drain -- SKIP"; continue; fi
  ob=$(awk -F';' 'NR==FNR{o[$1]=1;next} o[$5]{s+=$2}END{printf "%.3f",s/1e9}' /tmp/odp.$V $d/$base.$V.$l.blob.idx 2>/dev/null)
  ot=$(awk -F';' 'NR==FNR{o[$1]=1;next} o[$5]{s+=$2}END{printf "%.3f",s/1e9}' /tmp/odp.$V $d/$base.$V.$l.tree.idx 2>/dev/null)
  if awk "BEGIN{exit !($ob==0 && $ot==0)}"; then
    echo "## $V.$l CLEAN (off blob=$ob tree=$ot) -> drain"
    drainbg "$l"
  else
    echo "######## DEOFF $V.$l (off blob=${ob}GB tree=${ot}GB) $(date '+%T') ########"
    need=$(du -sb $d/$base.$V.$l.blob.bin 2>/dev/null|cut -f1); free=$(df -B1 --output=avail $d|tail -1)
    [ "$free" -lt "$need" ] && { echo "  low space -- waiting for drains"; wait; }
    /home/exouser/bin/filterDeoffShard.sh "$V" "$l"
    rb=$(awk -F';' 'NR==FNR{o[$1]=1;next} o[$5]{s+=$2}END{printf "%.3f",s/1e9}' /tmp/odp.$V $d/$base.$V.$l.blob.idx 2>/dev/null)
    rt=$(awk -F';' 'NR==FNR{o[$1]=1;next} o[$5]{s+=$2}END{printf "%.3f",s/1e9}' /tmp/odp.$V $d/$base.$V.$l.tree.idx 2>/dev/null)
    echo "  $V.$l residual blob=${rb}GB tree=${rt}GB"
    if awk "BEGIN{exit !($rb==0 && $rt==0)}"; then drainbg "$l"; else echo "  $V.$l residual NONZERO -- NOT draining"; fi
  fi
done
wait
echo "=== $V deoff+drain DONE $(date '+%F %T') ==="; df -h $d|tail -1
