#!/usr/bin/perl
# verify.pl <type> <shard_basepath> [N] [sec]
# shard_basepath = .../commit_<sec>  (expects .bin + .idx). Samples N idx records,
# reads (off,len) from .bin, LZF-decompresses, recomputes git sha, asserts ==.
use strict; use warnings;
use Compress::LZF ();
use Digest::SHA qw(sha1_hex);
my ($type,$base,$N,$sec)=@ARGV; $N//=2000;
open(my $I,'<',"$base.idx") or die "$base.idx: $!";
open(my $B,'<',"$base.bin") or die "$base.bin: $!";
my @lines=<$I>; close $I;
my $tot=scalar @lines; my $step=$tot>$N? int($tot/$N):1;
my ($ok,$bad,$chk)=(0,0,0);
for(my $i=0;$i<$tot;$i+=$step){
  my ($id,$off,$len,$sha)=split/;/, $lines[$i]; chomp $sha;
  seek($B,$off,0); my $c; read($B,$c,$len);
  my $code=Compress::LZF::decompress($c);
  my $ul=length($code);
  my $h=sha1_hex("$type $ul\0$code");
  $chk++;
  if($h eq $sha){$ok++}else{$bad++; print "MISMATCH id=$id off=$off len=$len idx=$sha got=$h\n" if $bad<=5;}
}
print "verify $type $base: checked=$chk ok=$ok bad=$bad (total recs=$tot)\n";
exit($bad?1:0);
