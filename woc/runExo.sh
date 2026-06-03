ver=$2
m=$1
out=${3:-out}
DT=202605
base=New$DT$ver



[[ -d $ver.$m ]] || exit
DST=/media/volume/$out/$ver.$m
mkdir -p $DST
cd $ver.$m


cp list$DT.${ver}1.$m  CopyList.${ver}1.$m
nlines=$(cat CopyList.${ver}1.$m |wc -l);  
part=$(echo "$nlines/16 + 1"|bc);  
cat CopyList.${ver}1.$m | split -l $part --numeric-suffixes - CopyList.${ver}1.$m.


for l in {00..15}
do 
(cat CopyList.${ver}1.$m.$l | while read repo; do  [[ -d $repo/ ]] && $HOME/bin/gitListSimp.sh $repo | $HOME/bin/classify $repo 2>> $DST/$base.$m.$l.olist.err
done | gzip > $DST/$base.$m.$l.olist.gz; \
zcat $DST/$base.$m.$l.olist.gz | ssh da5 -At '$HOME/lookup/cleanBlb.perl | $HOME/bin/hasObj.perl' | gzip > $DST/todo.$m.$l) & 
#rsync -av *.$l.olist.gz da5:/data/play/$ver/; \
#ssh da5 "/data/play/V4/toTodo1.sh $m $l" < /dev/null
#) &
done

wait
#rsync -av list202406* *.olist.gz da8:/mnt/ordos/data/data/update/V4/
#rsync -av *.olist.gz da5:/data/play/$ver/

# run on da5
#ssh da5 "/da8_data/update/V4/toTodo.sh $m"

#rsync -av da5:/data/play/$ver/todo.$m.* .
#for l in {00..15}; do sleep 1; [[ ! -f todo.$m.$l  || 0 -eq $(zcat todo.$m.$l|wc -l) ]] && ssh da5 "/data/play/$ver/toTodo1.sh $m $l" < /dev/null & done
#wait
#rsync -av da5:/data/play/$ver/todo.$m.* .

zcat $DST/todo.$m.[0-2][0-9] | gzip > $DST/todo.$m


nlines=$(zcat $DST/todo.$m |wc -l)
part=$(echo "$nlines/16 + 1"|bc)
zcat $DST/todo.$m | split -l $part -a2 -d  --filter='gzip > $FILE.gz' - $DST/$base.$m.olist.


for l in {00..15} 
do gunzip -c $DST/$base.$m.olist.$l.gz | perl -I $HOME/lib64/perl5 $HOME/bin/grabGitI.perl $DST/$base.$m.$l 2> $DST/$base.$m.$l.err &
done

# Some repos take days to grab; de-offend oversized shards every ~30 min while
# the grabs (and any relaunched de-offended grabs) are still running. The pgrep
# loop also waits for those relaunches to finish before the rsync below.
# (deOffendWatch.sh in cron is a separate safety net; deOffend.sh locks per
# dataset so the two never race.)
elapsed=0
while pgrep -f "grabGitI(Type)?\.perl .*/$base\.$m\." >/dev/null 2>&1; do
  sleep 60; elapsed=$((elapsed+60))
  if (( elapsed >= 1800 )); then $HOME/bin/deOffend.sh $m $ver $out; elapsed=0; fi
done
wait 2>/dev/null
$HOME/bin/deOffend.sh $m $ver $out      # final sweep for shards finished between polls

rsync -av list$DT.* $DST/*.olist.gz $DST/*.{blob,commit,tree,tag}.{bin,idx} da8:/mnt/ordos/data/data/update/$ver/ \
  && echo "rsynced $(date '+%F %T')" > /media/volume/trees/$ver.$m/STAGE
# The repo-folder STAGE marker progresses: rsynced -> verified. This deOffend
# call confirms no oversized shards remain and upgrades STAGE to "verified ..."
# -- then it is safe to delete the repo clones and the dumps. (The cron
# watchdog also performs this upgrade as a safety net.)
$HOME/bin/deOffend.sh $m $ver $out
#cat list$DT.${ver}1.* | while read i; do [[ -d $i ]] && find $i -delete; done &

