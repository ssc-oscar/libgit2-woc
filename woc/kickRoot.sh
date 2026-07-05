#!/bin/bash
# kickRoot.sh <V> -- a stuck-clone root (clones ~done, driver hung on unreachable tail) into
# grabbing: kill clone drivers, build V26051 from present bare-repo dirs (=mangled names),
# STAGE=listed, launch runExoSeq (rolling, auto-drainer) from /media/volume/trees.
set -u
V=${1:?usage: kickRoot.sh <dataset>}; d=/media/volume/trees/V2605.$V
[ -d "$d" ] || { echo "$V: no clonedir"; exit 1; }
for p in $(ls /proc|grep -E '^[0-9]+$'); do
  case "$(tr '\0' ' ' </proc/$p/cmdline 2>/dev/null)" in
    *"fetchExoSeq.sh $V "*|*"doOtrVerFetch.sh $V "*) kill -9 "$p" 2>/dev/null;;
  esac
done
for p in $(pgrep -x git); do case "$(readlink /proc/$p/cwd 2>/dev/null)" in *V2605.$V/*|*V2605.$V) kill -9 "$p" 2>/dev/null;; esac; done
sleep 2
( cd "$d" && find . -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | LC_ALL=C sort > list202605.V26051.$V )
n=$(wc -l < "$d/list202605.V26051.$V")
echo "$V: V26051 = $n present repos"
[ "$n" -lt 10000 ] && { echo "$V: too few ($n) -- NOT kicking"; exit 1; }
echo "listed $(date '+%F %T')" > "$d/STAGE"
nohup setsid bash -c "cd /media/volume/trees && exec bash /home/exouser/bin/runExoSeq.sh $V V2605 out" > /media/volume/trees/runExoSeq$V.log 2>&1 < /dev/null &
echo "$V: launched runExoSeq (rolling, SHARD_PAR=2)"
