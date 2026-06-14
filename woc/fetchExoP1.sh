#!/bin/bash
# fetchExoP1.sh <m> <ver> <DT> [out] [filter]      e.g. fetchExoP1.sh 071 V2605 202605 out blob:none
#
# PHASE 1 of two-phase, deferred-blob extraction (opt-in; the normal full path is
# fetchExo.sh). Fetches ONLY commits+trees now (filter blob:none by default) and
# PERSISTS the per-repo blob backfill want-list while the partial repos still
# exist -- because there is not enough disk to keep repos for phase 2; once this
# finishes and rsyncs, the repos can be deleted and the blobs fetched later with
# backfillExo.sh purely from the persisted list.
#
# Most valuable for UPDATED repos (tips/haves branch): haves + blob:none fetches
# only the NEW commits/trees beyond WoC and no blobs -- tiny and fast even for
# huge repos. New repos are filtered too (partial mirror clone) when filter set.
#
# Steps:
#   1. doOtrVerFetch.sh with FILTER set  -> partial repos (commits+trees only)
#   2. backfillList over present repos | da5 cleanBlb|hasObj  -> backfill.$m.gz
#      (blob OIDs referenced by trees that WoC does NOT already have)
#   3. urls.$m.gz : mangled-name -> upstream URL map (forge-correct, for phase 2)
#   4. runExo.sh  -> dump+rsync commits/trees (blob dumps are empty here)
#   5. rsync backfill.$m.gz + urls.$m.gz to da8; mark PHASE=blobs-pending
set -u
m=${1:?usage: fetchExoP1.sh <m> <ver> <DT> [out] [filter]}; ver=${2:?}; DT=${3:?}
out=${4:-out}; FILTER=${5:-blob:none}; export FILTER
. "${WOC_CONFIG:-$HOME/bin/jetstream2.config}" 2>/dev/null
: "${VOL:=/media/volume}"; : "${TREES:=$VOL/trees}"
: "${RSYNC_DEST:=da8:/mnt/ordos/data/data/update}"; : "${HASOBJ_HOST:=da5}"
cd "$TREES" || { echo "[p1 $ver.$m] cannot cd $TREES"; exit 1; }
DST=$VOL/$out/$ver.$m; mkdir -p "$DST"
pre=list$DT.$ver

echo "[p1 $ver.$m] FILTER=$FILTER clone/fetch start $(date '+%F %T')"
/home/exouser/bin/doOtrVerFetch.sh "$m" "$ver" "$DT" || { echo "[p1 $ver.$m] doOtrVerFetch FAILED"; exit 1; }

echo "[p1 $ver.$m] building backfill want-list (blobs referenced by trees, not in WoC)"
( cd "$ver.$m" && while read -r r; do
    [ -d "$r" ] && /home/exouser/bin/backfillList.sh "$r" "$r"
  done < "${pre}1.$m" ) \
  | ssh "$HASOBJ_HOST" -At '$HOME/lookup/cleanBlb.perl | $HOME/bin/hasObj.perl' \
  | pigz > "$DST/backfill.$m.gz"
echo "[p1 $ver.$m] backfill blobs pending: $(pigz -dc "$DST/backfill.$m.gz" | wc -l)"

# mangled-name -> URL map so phase 2 can rebuild the right URL for any forge
sed 's|a:a@||' "$ver.$m/$pre.$m" | perl -ne '
    chomp; my $i=$_;
    my $j=$i; $j=~s|^gh:([^/]+)/|$1_|; $j=~s|^bb:([^/]+)/|bitbucket.org_$1_|;
    $j=~s|^gl:([^/]+)/|gitlab.com_$1_|; $j=~s|^dr:([^/]+)/|drupal.com_$1_|;
    $j=~s|^https://([^/]*)/([^/]*)/|$1_$2_|; $j=~s|^https://([^/]*)/|$1_|;
    my $u=$i; $u=~s|^gh:|https://github.com/|; $u=~s|^bb:|https://bitbucket.org/|;
    $u=~s|^gl:|https://gitlab.com/|; $u=~s|^dr:|https://drupal.com/|;
    print "$j\t$u\n" if $j ne "";' | pigz > "$DST/urls.$m.gz"

echo "[p1 $ver.$m] dump+rsync commits/trees"
/home/exouser/bin/runExo.sh "$m" "$ver" "$out" || { echo "[p1 $ver.$m] runExo FAILED"; exit 1; }

rsync -a "$DST/backfill.$m.gz" "$DST/urls.$m.gz" "$RSYNC_DEST/$ver/" 2>/dev/null
echo "blobs-pending $(date '+%F %T')" > "$TREES/$ver.$m/PHASE"
echo "[p1 $ver.$m] DONE $(date '+%F %T'); repos may now be deleted; run backfillExo.sh for blobs"
