#!/bin/bash
# fetchTips.sh -- batch incremental fetch driven by WoC P2tips.
#
# Joins a WoC fetch list to a (sharded, compressed) tips map, then fetches ONLY
# each repo's PARTIAL set (objects beyond the WoC-known tips) via fetchNew.py into
# bare repos under OUT -- ready for mirrorUpdate.sh --initial + grab* (like a kept
# collection).
#
# Inputs:
#   * fetch list  : WoC shorthand, ORIGINAL case -- e.g. gh:Owner/Repo
#                   (gh->github.com, bb->bitbucket.org, gl->gitlab.com, dr->drupal.com;
#                    full https:// URLs also accepted; other prefixes e.g. deb: skipped).
#   * tips        : the WoC tips map as 'p;commit' lines (one tip per line). May be:
#                   - a DIRECTORY of shards (e.g. /media/volume/trees/p2tips holding
#                     p2tipsFull.V2604.0.s .. .127.s), OR a single file, OR a glob.
#                   - each shard may be pigz/gzip-compressed (auto-detected by magic)
#                     or plain text.
#                   The key 'p' is NORMALIZED (lowercase, protocol dropped, first two
#                   '/' -> '_', leading 'github.com_' dropped). It is LOSSY, so the
#                   FETCH URL comes from the LIST (original case); the key is used
#                   ONLY to look up tips. GitHub owners cannot contain '_', so the
#                   first '_' in a key is the owner/repo boundary.
#                   The full map is huge, so it is STREAM-FILTERED to just the list's
#                   keys (only those repos' tips are held in memory).
#
# p2tips ('p;..', lowercase/deforked) -> JOIN DIRECTLY (default).
# P2tips ('P' space) -> pass --keymap FILE ('listkey<TAB>tipskey', one-to-many) so
#   the normalized list key is run through the p2P transformation before lookup.
#
#   fetchTips.sh <list> <tips-dir|file|glob> [--keymap FILE] [--out DIR] [--par N] [--limit N]
# Downstream (cwd = OUT):
#   mirrorUpdate.sh "$OUT" --initial --out new.olist   # list all fetched objects
#   cat new.olist | perl -I ~/lib64/perl5 ~/bin/grabGitI.perl <base>
set -u
LIST=${1:?usage: fetchTips.sh <list> <tips-dir|file|glob> [--keymap F] [--out DIR] [--par N] [--limit N]}
P2T=${2:?need tips (directory of shards, file, or glob)}; shift 2
OUT=./tipsfetch; PAR=8; LIM=0; KEYMAP=""
while [ $# -gt 0 ]; do case $1 in
  --out) OUT=$2; shift 2;; --par) PAR=$2; shift 2;; --limit) LIM=$2; shift 2;;
  --keymap) KEYMAP=$2; shift 2;; *) shift;; esac; done
mkdir -p "$OUT"; WORK=$(mktemp -d); export OUT

# resolve tips shards: directory -> p2tipsFull.* (fallback all files); else glob/file
if [ -d "$P2T" ]; then
  mapfile -t SHARDS < <(ls "$P2T"/p2tipsFull.* 2>/dev/null); [ ${#SHARDS[@]} -eq 0 ] && mapfile -t SHARDS < <(ls "$P2T"/* 2>/dev/null)
else
  mapfile -t SHARDS < <(ls $P2T 2>/dev/null)
fi
[ ${#SHARDS[@]} -eq 0 ] && { echo "no tips shards found for: $P2T" >&2; exit 1; }
echo "tips shards: ${#SHARDS[@]}"

# Phase 1: list-key-driven stream-filter join -> (url<TAB>key<TAB>csv-tips)
perl -e '
  my ($list,$keymap,$lim,@tipfiles)=@ARGV;
  my $GZ = (system("command -v pigz >/dev/null 2>&1")==0) ? "pigz" : "gzip";
  sub openf { my $f=shift; open(my $h,"<:raw",$f) or die "$f: $!"; my $m=""; read($h,$m,2); close $h;
    if($m eq "\x1f\x8b"){ open(my $g,"-|",$GZ,"-dc",$f) or die "$GZ $f: $!"; return $g; }
    open(my $p,"<",$f) or die "$f: $!"; return $p; }
  # keymap (p2P): listkey -> [tipkeys]
  my %M;
  if($keymap && -s $keymap){ open my $K,"<",$keymap or die "$keymap: $!";
    while(<$K>){ chomp; my($a,$b)=split/\t/,$_,2; next unless defined $b && $b ne ""; push @{$M{$a}}, $b; } }
  # list -> entries(url,key,[tipkeys]) + the set of tipkeys we need from the map
  my %PRE=(gh=>"github.com",bb=>"bitbucket.org",gl=>"gitlab.com",dr=>"drupal.com");
  my (@E,%need); open my $L,"<",$list or die "$list: $!"; my $n=0;
  while(<$L>){ chomp; my $e=$_; next if $e eq "";
    my ($host,$rest);
    if($e=~/^([a-z]+):(.+)$/ && $PRE{$1}){ $host=$PRE{$1}; $rest=$2; }
    elsif($e=~m|^https?://([^/]+)/(.+?)/?$|){ $host=$1; $rest=$2; }
    else { next; }                                   # unknown prefix (deb: ...) -> skip
    my $url="https://$host/$rest";
    my $key=lc("$host/$rest"); $key=~s|/|_|g; $key=~s|^github\.com_||;
    my @lk = (%M ? ($M{$key} ? @{$M{$key}} : ()) : ($key));
    push @E, [$url,$key,\@lk]; $need{$_}=1 for @lk;
    last if $lim && ++$n>=$lim;
  }
  # stream the (possibly compressed) tip shards, keeping only needed keys
  my %T;
  for my $tf (@tipfiles){ my $fh=openf($tf);
    while(<$fh>){ chomp; my $i=index($_,";"); next if $i<0; my $k=substr($_,0,$i);
      next unless $need{$k}; my $s=substr($_,$i+1); next if $s eq ""; push @{$T{$k}}, $s; }
    close $fh; }
  # emit jobs
  for my $r (@E){ my ($url,$key,$lk)=@$r; my (%seen,@tips);
    for my $tk (@$lk){ next unless $T{$tk}; for my $s (@{$T{$tk}}){ push @tips,$s unless $seen{$s}++; } }
    print "$url\t$key\t".join(",",@tips)."\n"; }
' "$LIST" "$KEYMAP" "$LIM" "${SHARDS[@]}" > "$WORK/jobs.tsv"
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
