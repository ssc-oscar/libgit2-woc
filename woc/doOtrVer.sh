#!/bin/bash
k=$1
ver=$2
DT=$3
dir=$ver.$k
pre=list$DT.$ver
cd $dir
# unified lifecycle marker in the repo folder:
#   cloning -> listed -> grabbing -> rsynced -> verified
echo "cloning $(date '+%F %T')" > STAGE
cat $pre.$k | sed 's|a:a@||' | while read i; do j=$(echo $i|perl -ane 's|^gh:([^/]+)/|$1_|;s|^bb:([^/]+)/|bitbucket.org_$1_|;s|^gl:([^/]+)/|gitlab.com_$1_|;s|^dr:([^/]+)/|drupal.com_$1_|;s|^https://([^/]*)/([^/]*)/|$1_$2_|;s|^https://([^/]*)/|$1_|;print'); r=$(echo $i|sed 's|^https://|https://a:a@|;s|^https://a:a@git.launchpad.net/|lp:|'); [[ -d $j ]] || git clone --mirror $r $j; done &
tac $pre.$k | sed 's|a:a@||' | while read i; do j=$(echo $i|perl -ane 's|^gh:([^/]+)/|$1_|;s|^bb:([^/]+)/|bitbucket.org_$1_|;s|^gl:([^/]+)/|gitlab.com_$1_|;s|^dr:([^/]+)/|drupal.com_$1_|;s|^https://([^/]*)/([^/]*)/|$1_$2_|;s|^https://([^/]*)/|$1_|;print'); r=$(echo $i|sed 's|^https://|https://a:a@|;s|^https://a:a@git.launchpad.net/|lp:|'); [[ -d $j ]] || git clone --mirror $r $j; done &
cat $pre.$k | sed 's|a:a@||' | while read i; do j=$(echo $i|perl -ane 's|^gh:([^/]+)/|$1_|;s|^bb:([^/]+)/|bitbucket.org_$1_|;s|^gl:([^/]+)/|gitlab.com_$1_|;s|^dr:([^/]+)/|drupal.com_$1_|;s|^https://([^/]*)/([^/]*)/|$1_$2_|;s|^https://([^/]*)/|$1_|;print'); r=$(echo $i|sed 's|^https://|https://a:a@|;s|^https://a:a@git.launchpad.net/|lp:|'); [[ -d $j ]] || git clone --mirror $r $j; done &
tac $pre.$k | sed 's|a:a@||' | while read i; do j=$(echo $i|perl -ane 's|^gh:([^/]+)/|$1_|;s|^bb:([^/]+)/|bitbucket.org_$1_|;s|^gl:([^/]+)/|gitlab.com_$1_|;s|^dr:([^/]+)/|drupal.com_$1_|;s|^https://([^/]*)/([^/]*)/|$1_$2_|;s|^https://([^/]*)/|$1_|;print'); r=$(echo $i|sed 's|^https://|https://a:a@|;s|^https://a:a@git.launchpad.net/|lp:|'); [[ -d $j ]] || git clone --mirror $r $j; done &
wait

cat $pre.$k | sed 's|a:a@||' | while read i; 
do r=$(echo $i|perl -ane 's|^gh:([^/]+)/|$1_|;s|^bb:([^/]+)/|bitbucket.org_$1_|;s|^gl:([^/]+)/|gitlab.com_$1_|;s|^dr:([^/]+)/|drupal.com_$1_|;s|^https://([^/]*)/([^/]*)/|$1_$2_|;s|^https://([^/]*)/|$1_|;print'); \
	[[ -d $r ]] && echo $r; done > ${pre}1.$k

#cat $pre.$k | perl -ane '$a=$_;s|^bb:([^/]+)/|bitbucket.org_$1_|;s|^gl:([^/]+)/|gitlab.com_$1_|;s|^dr:([^/]+)/|drupal.com_$1_|;s|^https://([^/]*)/([^/]*)/|$1_$2_|;s|^https://([^/]*)/|$1_|;s|\n$||;print "$_;$a"' | \
#   lsort 1M -u -t\; -k1,1 | join -t\; -v1 - <(lsort 1M -u -t\; -k1,1 ${pre}1.$k) | grep -Ev ';(gl|bb):' | lsort 1M -t\; -R -k1,1  > miss.$k
#cat miss.$k |sed 's|a:a@||g' | while IFS=\; read d r; do r=$(echo $r|sed 's|^https://|https://a:a@|'); git clone --mirror $r.git $d; done
#cut -d\; -f1 miss.$k | while read r; do [[ -d $r ]] && echo $r; done >> ${pre}1.$k

echo "listing $(date '+%F %T')" > STAGE
#awk '{print $2}' ${pre}.$k.s > ${pre}.$k
cat ${pre}1.$k | while read i; do [[ -f $i/packed-refs ]] && echo $i/packed-refs;done | cpio -o | gzip > ../${pre}.$k.cpio.gz
# clone/list stage complete -> runExo.sh may proceed
echo "listed $(date '+%F %T')" > STAGE
