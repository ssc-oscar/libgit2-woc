#!/bin/bash
# distQuant.sh <stats.txt|->  -- depth/size distribution from a cmputeDiffGen STATS run (plain text).
# stats line = commit;rootLen;nTree;maxDepth;nBlobEntries;totTreeBytes;capped
gawk -F';' '
  { n++; if($7==1)cap++; if($2<0){miss++; next} }
  { rl[++k]=$2; nt[k]=$3; dp[k]=$4; ne[k]=$5; tb[k]=$6 }
  END{
    printf "N=%d  tree-miss=%d (%.2f%%)  capped=%d (%.3f%%)  measured=%d\n",
           n, miss, n?100*miss/n:0, cap, n?100*cap/n:0, k
    if(!k) exit
    rep("totTreeBytes", tb, k); rep("maxDepth", dp, k)
    rep("nTreeObjs", nt, k); rep("nBlobEntries", ne, k); rep("rootLen", rl, k)
  }
  function rep(nm,a,k, i,s,q){ for(i=1;i<=k;i++) s[i]=a[i]; asort(s)
    printf "%-13s min=%d med=%d max=%d", nm, s[1], s[int((k+1)/2)], s[k]
    for(q=0;q<3;q++){ split("0.99 0.999 0.9999",Q," "); i=int(Q[q+1]*k); if(i<1)i=1
      printf "  q%s=%d", Q[q+1], s[i] }
    printf "\n" }' "$1"
