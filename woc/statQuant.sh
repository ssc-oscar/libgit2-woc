#!/bin/bash
# statQuant.sh <stats.gz> -- distribution report for a cmputeDiffGen STATS run.
# stats line = commit;rootLen;nTree;maxDepth;nBlobEntries;totTreeBytes;capped
# Reports N, tree-miss rate (rootLen<0), and .99/.999/.9999 quantiles of the cost metrics.
set -eu
f=${1:?usage: statQuant.sh <stats.gz>}
zcat "$f" | awk -F';' '
  { n++; if($7==1)cap++; if ($2<0){miss++; next} }   # rootLen<0 == tree unresolvable; $7 == walk hit node cap
  { rl[++k]=$2; nt[k]=$3; dp[k]=$4; ne[k]=$5; tb[k]=$6 }
  END{
    printf "N=%d  tree-miss(rootLen<0)=%d (%.3f%%)  capped(monster)=%d (%.3f%%)  measured=%d\n", n, miss, n?100.0*miss/n:0, cap, n?100.0*cap/n:0, k
    if(!k) exit
    split("",Q); Q[1]=0.99; Q[2]=0.999; Q[3]=0.9999
    report("rootLen(stored)", rl, k); report("totTreeBytes", tb, k)
    report("maxDepth", dp, k); report("nTreeObjs", nt, k); report("nBlobEntries", ne, k)
  }
  function report(name, arr, k,   i, srt, q, idx){
    for(i=1;i<=k;i++) srt[i]=arr[i]
    asort(srt)
    printf "%-16s  min=%d  median=%d  max=%d", name, srt[1], srt[int((k+1)/2)], srt[k]
    for(q=1;q<=3;q++){ idx=int(Q[q]*k); if(idx<1)idx=1; printf "  q%s=%d", (q==1?".99":(q==2?".999":".9999")), srt[idx] }
    printf "\n"
  }'
