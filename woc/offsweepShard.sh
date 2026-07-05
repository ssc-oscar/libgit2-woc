#!/bin/bash
# offsweepShard.sh <dataset> <shard> [kill]
# largest.sh detection pass on ONE grab shard (blob+tree idx, partial or complete).
# AUTO-REGISTERS high-confidence offenders BEFORE deoff (atomic), logs the rest for review.
#   auto-register if:  tree>=4GB (tree-bomb)  OR  blob>=40GB  OR  (blob>=5GB AND repo is
#                      >=50% of the shard's total blob bytes = a dominant single-repo dump)
#   review-log if:     blob>=3GB OR tree>=1GB  (not auto, not already offender/keep)
# With 'kill': also SIGKILL the live grabf/grabft of each newly-auto-registered offender so a
# long-running grab (24h+ on a mega-dump) stops dumping it and grabGitI advances.
set -u
m=${1:?usage: offsweepShard.sh <dataset> <shard> [kill]}; l=${2:?}; mode=${3:-}
REG=/media/volume/trees/offenders; KEEP=/media/volume/trees/keep
REVIEW=/media/volume/trees/offsweep.review
d=""; for c in /media/volume/b/V2605.$m /media/volume/out/V2605.$m; do [ -d "$c" ] && { d="$c"; break; }; done
[ -z "$d" ] && exit 0
base=New202605V2605; pre="$d/$base.$m.$l"
[ -f "$pre.blob.idx" ] || exit 0
export LC_ALL=C
cut -d';' -f1 "$REG" 2>/dev/null | sort -u > "/tmp/osw.off.$m.$l"
grep -vE '^#|^$' "$KEEP" 2>/dev/null | sort -u > "/tmp/osw.keep.$m.$l"
awk -F';' '{b[$5]+=$2; n[$5]++; tot+=$2} END{for(r in b) print "B;"r";"b[r]";"n[r]; print "TOT;;"tot}' "$pre.blob.idx" > "/tmp/osw.bt.$m.$l"
[ -f "$pre.tree.idx" ] && awk -F';' '{t[$5]+=$2} END{for(r in t) print "T;"r";"t[r]}' "$pre.tree.idx" >> "/tmp/osw.bt.$m.$l"
awk -F';' -v OFF="/tmp/osw.off.$m.$l" -v KEEP="/tmp/osw.keep.$m.$l" '
  BEGIN{ while((getline x<OFF)>0)o[x]=1; while((getline x<KEEP)>0)k[x]=1 }
  $1=="TOT"{tot=$3; next} $1=="B"{b[$2]=$3; nb[$2]=$4; reps[$2]=1} $1=="T"{t[$2]=$3; reps[$2]=1}
  END{ for(r in reps){ if(o[r]||k[r])continue; bb=b[r]+0; tt=t[r]+0; cc=nb[r]+0; sh=(tot>0)?bb/tot:0
      auto=(tt>=4e9 || bb>=40e9 || (bb>=5e9 && sh>=0.5)); inband=(bb>=3e9 || tt>=1e9)
      # BLOB-COUNT signal: a repo with a huge NUMBER of blobs is a grab-time HOG (per-object
      # inflate+SHA overhead x count) even when total size is tiny -- e.g. github.io sites and
      # release/log dumps with 100k+ small blobs. Size thresholds miss these; count catches them.
      # Auto-register only when a data-dump keyword ALSO matches (a legit large-history fork can
      # have many blobs); otherwise review-log so a human decides. ctband high-count -> review.
      ctbomb=(cc>=250000); ctband=(cc>=100000)
      # SUSPICIOUS-KEYWORD auto-register: a review-band repo whose name carries a high-confidence
      # data-dump token (proxy/blocklist/scraper/raw-data/site/etc.) auto-registers regardless of
      # dominance -- closes the gap for non-dominant proxy/blocklist dumps that else need manual triage.
      kw=(tolower(r) ~ /(proxy|v2ray|vmess|trojan|shadowsocks|sing.?box|mihomo|surfboard|hysteria|clash.?(meta|rule)|blocklist|blacklist|denylist|adblock|adguard|oisd|easylist|filterlist|hostlist|scam.?link|phish|scrape|rss|lava|rule.?set|raw.?data|market.?data|dataset|scraper|crawler|leaderboard|github\.io|iptv|m3u8?|playlist)/)
      if(auto || (inband && kw) || (ctbomb && kw)) printf "AUTO;%s;%.1f;%.1f;%.2f;%s;%d\n",r,bb/1e9,tt/1e9,sh,(auto?"size":(ctbomb?"count":"keyword")),cc
      else if(inband || ctband) printf "REVIEW;%s;%.1f;%.1f;%.2f;%d\n",r,bb/1e9,tt/1e9,sh,cc } }' "/tmp/osw.bt.$m.$l" > "/tmp/osw.dec.$m.$l"

autoreg=$(awk -F';' '$1=="AUTO"{print $2}' "/tmp/osw.dec.$m.$l")
if [ -n "$autoreg" ]; then
  while IFS=';' read -r tag repo bgb tgb sh trig cnt; do
    [ "$tag" = AUTO ] || continue
    grep -q "^$repo;" "$REG" || echo "$repo;${bgb}GB-blob/${tgb}GB-tree/${cnt}-blobs;auto-offsweep $(date '+%F');shard $m.$l, ${sh} blob-share, trigger=${trig} -- auto-detected dump" >> "$REG"
    echo "$(date '+%F %T') AUTO-OFFENDER($trig) $m.$l $repo blob=${bgb}GB tree=${tgb}GB share=${sh} blobs=${cnt}" >> "$REVIEW"
  done < "/tmp/osw.dec.$m.$l"
  /home/exouser/bin/regsort.sh "$REG"
  cp -a "$REG" /media/volume/trees/src/libgit2-woc/woc/offenders 2>/dev/null
  if [ "$mode" = kill ]; then
    for repo in $autoreg; do
      pkill -9 -f "grab(f|ft) $repo\$" 2>/dev/null && echo "$(date '+%F %T') KILLED grab of $repo on $m.$l (long-running offender)" >> "$REVIEW"
      pkill -9 -f "New202605V2605.$m.$l.(blob|tree).$repo\$" 2>/dev/null
    done
  fi
fi
# log review candidates (dedup by repo into the review file)
awk -F';' -v M="$m.$l" '$1=="REVIEW"{print strftime("%F %T")" REVIEW "M" "$2" blob="$3"GB tree="$4"GB share="$5" blobs="$6}' "/tmp/osw.dec.$m.$l" >> "$REVIEW" 2>/dev/null
rm -f "/tmp/osw.off.$m.$l" "/tmp/osw.keep.$m.$l" "/tmp/osw.bt.$m.$l" "/tmp/osw.dec.$m.$l"
[ -n "$autoreg" ] && echo "offsweep $m.$l auto-registered: $(echo $autoreg|tr '\n' ' ')"
exit 0
