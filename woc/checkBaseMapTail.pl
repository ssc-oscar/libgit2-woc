#!/usr/bin/perl
# checkBaseMapTail.pl <idxdir> <type> <tchprefix>
#   For each section 0..127: take the LAST object of <idxdir>/<type>_<sec>.idx (tail -1, sha=field4)
#   and assert it is a key in <tchprefix><sec>.tch. Confirms the (frozen base) map covers the whole
#   base idx. Works for offset maps (All.sha1o/sha1.<type>_) and content maps (All.sha1c/<type>_).
use lib ("$ENV{HOME}/lookup"); use strict; use warnings;   # NOT ~/lib64/perl5 (stale TokyoCabinet.so)
use TokyoCabinet;
my ($idxdir,$type,$tchpre) = @ARGV;
die "usage: checkBaseMapTail.pl <idxdir> <type> <tchprefix>\n" unless $tchpre;
my ($ok,$miss,$err)=(0,0,0);
for my $s (0..127){
  my $idx="$idxdir/${type}_$s.idx";
  unless (-s $idx){ print "NOIDX $idx\n"; $err++; next; }
  my $last=`tail -1 "$idx" 2>/dev/null`; chomp $last;
  my $sha=(split/;/,$last,-1)[3];
  unless (defined $sha && $sha=~/^[0-9a-f]{40}$/){ print "BADSHA sec $s: $last\n"; $err++; next; }
  my $tch="$tchpre$s.tch";
  my $hdb=TokyoCabinet::HDB->new;
  unless ($hdb->open($tch, $hdb->OREADER | $hdb->ONOLCK)){ print "NOOPEN $tch: ".$hdb->errmsg($hdb->ecode)."\n"; $err++; next; }
  my $v=$hdb->get(pack("H*",$sha)); $hdb->close;
  if (defined $v){ $ok++ } else { $miss++; print "MISSING sec $s sha=$sha in $tch\n"; }
}
print "[$type via $tchpre] OK=$ok MISSING=$miss ERR=$err  (want OK=128)\n";
