#!/bin/bash
# mkTipsFiles.sh <tips-dir> <ver> <DT> <k...>
# For each folder <ver>.<k>, read list<DT>.<ver>.<k> IN ORDER and write a
# line-aligned tips<DT>.<ver>.<k>: line i = comma-separated WoC tips (commit
# SHAs) for the project on list line i, or EMPTY if that project has no tips
# (new repo). One streaming pass over the (huge, compressed) tips shards;
# only the lists' keys are held in memory. Prints coverage stats.
#
# The tips KEY is the normalized p2tips key (lowercase, protocol dropped, first
# two '/' -> '_', leading github.com_ dropped) -- matched against the map; the
# OUTPUT is line-aligned to the original list so doOtrVerFetch reads list+tips
# together.
#
# --haves = P2tips UNION dropcommitTips (coord/clone0/dropcommit-tips-haves.md):
# dropcommit (commit-bomb) repos are excluded from P2c and so have no p2tips rows,
# which made every version re-fetch their full spam history. Their tips are captured
# separately (captureDropcommitTips.sh, repo;tip_sha, same normalized key) and any
# dropcommitTips.* file in <tips-dir> is streamed exactly like a p2tips shard.
# Stored/analyzed sets still EXCLUDE dropcommit commits -- this only feeds git
# negotiation so the fetch skips what we've already seen and dropped.
set -u
TIPS=${1:?usage: mkTipsFiles.sh <tips-dir> <ver> <DT> <k...>}; ver=${2:?}; DT=${3:?}; shift 3
perl -e '
  my ($tips,$ver,$DT,@ks)=@ARGV;
  my $GZ=(system("command -v pigz >/dev/null 2>&1")==0)?"pigz":"gzip";
  my %PRE=(gh=>"github.com",bb=>"bitbucket.org",gl=>"gitlab.com",dr=>"drupal.com");
  sub norm { my $e=shift; my ($host,$rest);
    if($e=~/^([a-z]+):(.+)$/ && $PRE{$1}){ $host=$PRE{$1}; $rest=$2; }
    elsif($e=~m|^https?://([^/]+)/(.+?)/?$|){ $host=$1; $rest=$2; }
    else { return undef; }
    my $k=lc("$host/$rest"); $k=~s|/|_|g; $k=~s|^github\.com_||; return $k; }
  # 1. load needed keys from all lists
  my %need; my $rows=0;
  for my $k (@ks){ my $lf="$ver.$k/list$DT.$ver.$k"; open my $L,"<",$lf or die "$lf: $!";
    while(<$L>){ chomp; next if $_ eq ""; $rows++; my $key=norm($_); $need{$key}=undef if defined $key; }
    close $L; }
  my $uniq=scalar keys %need;
  warn "loaded $rows rows, $uniq unique keys across ".scalar(@ks)." folders; streaming tips...\n";
  # 2. stream the tips shards, accumulating tips for needed keys
  my @sh=(glob("$tips/p2tipsFull.*"), glob("$tips/dropcommitTips.*")); my $sn=0;
  for my $f (@sh){ open(my $fh,"-|",$GZ,"-dc",$f) or next; $sn++;
    while(<$fh>){ my $i=index($_,";"); next if $i<0; my $p=substr($_,0,$i);
      next unless exists $need{$p}; my $c=substr($_,$i+1); chomp $c; next if $c eq "";
      $need{$p}=(defined $need{$p}?$need{$p}.",":"").$c; }
    close $fh; warn "  shard $sn/".scalar(@sh)." done\n"; }
  # 3. emit per-folder line-aligned tips files
  for my $k (@ks){ my $lf="$ver.$k/list$DT.$ver.$k"; my $of="$ver.$k/tips$DT.$ver.$k";
    open my $L,"<",$lf or die; open my $O,">",$of or die;
    while(<$L>){ chomp; my $key=norm($_); my $t=(defined $key && defined $need{$key})?$need{$key}:"";
      print $O "$t\n"; }
    close $L; close $O; }
  my $cov=0; for(values %need){ $cov++ if defined $_; }
  printf "rows=%d unique-projects=%d covered=%d (%.1f%%) NEW=%d (%.1f%%) shards=%d\n",
    $rows,$uniq,$cov,100*$cov/($uniq||1),$uniq-$cov,100*($uniq-$cov)/($uniq||1),$sn;
' "$TIPS" "$ver" "$DT" "$@"
