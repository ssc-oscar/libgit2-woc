#!/bin/bash
# fetchTips.sh -- batch incremental fetch driven by WoC P2tips.
#
# Joins a WoC fetch list to a P2tips file, then fetches ONLY each repo's PARTIAL
# set (objects beyond the WoC-known tips) via fetchNew.py into bare repos under
# OUT -- ready for mirrorUpdate.sh --initial + grab* (same as a kept collection).
#
# Input forms (this is the caveat the join must respect):
#   * fetch list  : WoC shorthand, ORIGINAL case -- e.g. gh:Owner/Repo
#                   (gh->github.com, bb->bitbucket.org, gl->gitlab.com, dr->drupal.com;
#                    full https:// URLs also accepted; other prefixes e.g. deb: skipped).
#   * tips file   : NORMALIZED 'key;tip_sha' lines, where key = lowercase, protocol
#                   dropped, first two '/' -> '_', leading 'github.com_' dropped.
# The tips key is LOSSY (lowercased, github.com_ stripped) so it cannot rebuild
# the URL -- the FETCH URL is taken from the LIST (original case); the key is used
# ONLY to look up that repo's tips. GitHub owners cannot contain '_', so the first
# '_' in a key is always the owner/repo boundary.
#
# p2tips vs P2tips:
#   * p2tips  : keyed in 'p' space == the normalized list key -> JOIN DIRECTLY.
#   * P2tips  : keyed in 'P' space -> the normalized list key must first be run
#               through the p2P transformation (WoC deforking map) to match.
#               Supply that map via --keymap FILE (lines 'listkey<TAB>tipskey',
#               one-to-many allowed: tips from all mapped keys are unioned).
#               Without --keymap the join is direct (p2tips mode).
#
#   fetchTips.sh <list> <tips> [--keymap FILE] [--out DIR] [--par N] [--limit N]
# Downstream (cwd = OUT):
#   mirrorUpdate.sh "$OUT" --initial --out new.olist   # list all fetched objects
#   cat new.olist | perl -I ~/lib64/perl5 ~/bin/grabGitI.perl <base>
set -u
LIST=${1:?usage: fetchTips.sh <list> <p2tips> [--out DIR] [--par N] [--limit N]}
P2T=${2:?need p2tips file}; shift 2
OUT=./tipsfetch; PAR=8; LIM=0; KEYMAP=""
while [ $# -gt 0 ]; do case $1 in
  --out) OUT=$2; shift 2;; --par) PAR=$2; shift 2;; --limit) LIM=$2; shift 2;;
  --keymap) KEYMAP=$2; shift 2;; *) shift;; esac; done
mkdir -p "$OUT"; WORK=$(mktemp -d); export OUT

# Phase 1: join list -> (url<TAB>key<TAB>csv-tips), P2tips loaded once into a hash.
perl -e '
  my ($p2,$list,$lim,$keymap)=@ARGV; my %T;
  open my $P,"<",$p2 or die "$p2: $!";
  while(<$P>){ chomp; next unless index($_,";")>=0; my($k,$s)=split/;/,$_,2;
    next unless defined $s && $s ne ""; push @{$T{$k}}, $s; }
  my %M;                                      # p2P keymap: listkey -> [tipkeys]
  if($keymap && -s $keymap){ open my $K,"<",$keymap or die "$keymap: $!";
    while(<$K>){ chomp; my($a,$b)=split/\t/,$_,2; next unless defined $b && $b ne "";
      push @{$M{$a}}, $b; } }
  my %PRE=(gh=>"github.com",bb=>"bitbucket.org",gl=>"gitlab.com",dr=>"drupal.com");
  open my $L,"<",$list or die "$list: $!"; my $n=0;
  while(<$L>){ chomp; my $e=$_; next if $e eq "";
    my ($host,$rest);
    if($e=~/^([a-z]+):(.+)$/ && $PRE{$1}){ $host=$PRE{$1}; $rest=$2; }
    elsif($e=~m|^https?://([^/]+)/(.+?)/?$|){ $host=$1; $rest=$2; }
    else { next; }                          # unknown prefix (e.g. deb:) -> skip
    my $url="https://$host/$rest";
    my $key=lc("$host/$rest"); $key=~s|/|_|g; $key=~s|^github\.com_||;
    # tip-lookup keys: direct (p2tips) unless a p2P keymap translates this key (P2tips)
    my @lk = (%M ? ($M{$key} ? @{$M{$key}} : ()) : ($key));
    my (%seen,@tips);
    for my $tk (@lk){ next unless $T{$tk}; for my $s (@{$T{$tk}}){ push @tips,$s unless $seen{$s}++; } }
    print "$url\t$key\t".join(",",@tips)."\n";
    last if $lim && ++$n>=$lim;
  }
' "$P2T" "$LIST" "$LIM" "$KEYMAP" > "$WORK/jobs.tsv"
total=$(wc -l <"$WORK/jobs.tsv"); withtips=$(awk -F'\t' '$3!=""' "$WORK/jobs.tsv" | wc -l)
echo "jobs=$total with-tips=$withtips (cold=$((total-withtips))) par=$PAR out=$OUT"

# Phase 2: parallel partial fetch (resumable: skip repos already fetched)
: > "$OUT/fetch.err"
fetch1(){
  local url=$1 key=$2 tips=$3 d="$OUT/$key"
  git --git-dir="$d" rev-parse --is-bare-repository >/dev/null 2>&1 && return  # done
  local args=("$url" --out "$d"); [ -n "$tips" ] && args+=(--haves "$tips")
  python3 "$HOME/bin/fetchNew.py" "${args[@]}" >> "$OUT/fetch.log" 2>>"$OUT/fetch.err" \
    || echo "FAIL $url" >> "$OUT/fetch.err"
}
export -f fetch1
n=0
while IFS=$'\t' read -r url key tips; do
  [ -z "$url" ] && continue
  fetch1 "$url" "$key" "$tips" &
  n=$((n+1)); (( n % PAR == 0 )) && wait
done < "$WORK/jobs.tsv"
wait
ok=$(find "$OUT" -maxdepth 1 -type d -name '*_*' | wc -l); fail=$(grep -c '^FAIL' "$OUT/fetch.err" 2>/dev/null)
echo "fetched bare repos: $ok   failures: ${fail:-0} (see $OUT/fetch.err)"
echo "next: mirrorUpdate.sh \"$OUT\" --initial --out \"$OUT/new.olist\"  then grabGitI.perl"
rm -rf "$WORK"
