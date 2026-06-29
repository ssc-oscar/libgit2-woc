#!/usr/bin/perl
# In-place offender removal: rewrite a .bin/.idx pair keeping only non-dropped objects.
# NO clones, NO decompression -- byte-copies each kept object's stored range and
# recomputes offsets. idx line = offset;storedlen;sec;sha;repo;...  (see checkBin1in.perl)
#
# usage: filterDeoff.pl <type> <prefix> <offenders-file> <keep-file> <blobonly-file> [<dropcommit-file>]
#   drops: offender repo's blob+tree ; blobonly repo's blob ; drop-commit repo's commit
#   (tags never dropped). dropcommit-file = one repo per line (deOffend's markc).
# writes <prefix>.deoff.<type>.{bin,idx}; prints kept/dropped counts to STDERR.
use strict; use warnings;
my ($type,$prefix,$offf,$keepf,$bof,$dcf) = @ARGV;
die "usage: filterDeoff.pl type prefix offenders keep blobonly [dropcommit]\n" unless $type && $prefix;

my %off;
if ($offf && open(my $F,'<',$offf)) { while(<$F>){chomp; my $r=(split/;/)[0]; $off{$r}=1 if defined $r && $r ne ''} close $F; }
if ($keepf && open(my $F,'<',$keepf)) { while(<$F>){chomp; next if /^#/ || $_ eq ''; delete $off{$_}} close $F; }
my %bo;
if ($bof && open(my $F,'<',$bof)) { while(<$F>){chomp; next if /^#/ || $_ eq ''; $bo{$_}=1} close $F; }
my %dc;
if ($dcf && open(my $F,'<',$dcf)) { while(<$F>){chomp; my $r=(split/;/)[0]; $dc{$r}=1 if defined $r && $r ne ''} close $F; }

open(my $IDX,'<',"$prefix.$type.idx") or die "open $prefix.$type.idx: $!";
open(my $BIN,'<:raw',"$prefix.$type.bin") or die "open $prefix.$type.bin: $!";
open(my $OIDX,'>',"$prefix.deoff.$type.idx") or die "write idx: $!";
open(my $OBIN,'>:raw',"$prefix.deoff.$type.bin") or die "write bin: $!";
my ($noff,$kept,$drop)=(0,0,0);
while (<$IDX>) {
  chomp; my @x = split(/;/, $_, -1);
  my ($o,$s,undef,undef,$repo) = @x;
  if (!defined $o || $o !~ /^\d+$/ || !defined $s || $s !~ /^\d+$/) { print STDERR "BADLINE $.: $_\n"; next; }
  my $dropit = ( ($off{$repo} && ($type eq 'blob' || $type eq 'tree'))
              || ($bo{$repo}  &&  $type eq 'blob')
              || ($dc{$repo}  &&  $type eq 'commit') );
  if ($dropit) { $drop++; next; }
  seek($BIN,$o,0); my $buf=''; my $r=read($BIN,$buf,$s);
  die "short read repo=$repo o=$o s=$s got=".(defined $r?$r:'undef')."\n" if !defined $r || $r != $s;
  print $OBIN $buf;
  $x[0] = $noff;
  print $OIDX join(';',@x)."\n";
  $noff += $s; $kept++;
}
close $OBIN; close $OIDX; close $IDX; close $BIN;
print STDERR "  [$type] kept=$kept dropped=$drop newbytes=$noff\n";
