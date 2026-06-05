#!/bin/bash
# Classify a bare repo's HEAD content to tell a data dump from real software.
# Prints:  files=N code=P% verdict=DATA|MIXED|CODE|UNKNOWN top: ext(n) ...
#   DATA  : <2%  of files are source code  -> data/log dump (exclude candidate)
#   MIXED : 2-10%                          -> look closer
#   CODE  : >10%                            -> real software (keep)
#   repoExt.sh /media/volume/trees/V2605.015/owner_repo
gd=$1
[[ -d $gd ]] || { echo "files=0 verdict=UNKNOWN"; exit 0; }
git --git-dir="$gd" ls-tree -r HEAD --name-only 2>/dev/null | head -200000 | awk -F/ '
  { f=$NF; nn=split(f,a,"."); e=(nn>1?tolower(a[nn]):"noext"); tot++; cnt[e]++
    if (e ~ /^(c|h|cpp|cc|cxx|hpp|hh|hxx|py|js|mjs|cjs|ts|jsx|tsx|java|go|rs|rb|php|cs|swift|kt|kts|scala|sh|bash|zsh|pl|pm|lua|sql|css|scss|less|vue|svelte|r|jl|dart|ex|exs|erl|clj|cljs|hs|ml|mli|fs|fsx|f|f90|f95|for|asm|s|vhd|vhdl|v|sv|gradle|cmake|mk|make|proto|tf|coffee|groovy|ipynb|rkt|nim|cr|zig|d|pas|ada|cob)$/) code++ }
  END { if (tot==0) { print "files=0 verdict=UNKNOWN"; exit }
        cp = 100*code/tot
        v = (cp<2 ? "DATA" : (cp<10 ? "MIXED" : "CODE"))
        m=""; for(i=0;i<3;i++){ best=""; bn=-1; for(k in cnt) if(cnt[k]>bn){bn=cnt[k]; best=k}
                                if(best=="") break; m=m" "best"("cnt[best]")"; delete cnt[best] }
        printf "files=%d code=%.1f%% verdict=%s top:%s\n", tot, cp, v, m }'
