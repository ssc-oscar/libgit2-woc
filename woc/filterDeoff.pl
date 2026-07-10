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
# Oversized-object guard: a single object bigger than this short-reads in convgen (and a bare
# read() caps ~2GB), so it can never enter the gen -- drop it here. Override with MAX_BLOB env.
my $MAXBLOB = defined $ENV{MAX_BLOB} ? $ENV{MAX_BLOB}+0 : 2147483647;   # ~2GB (2^31-1)

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
my ($noff,$kept,$drop,$big)=(0,0,0,0);
while (<$IDX>) {
  chomp; my @x = split(/;/, $_, -1);
  my ($o,$s,undef,undef,$repo) = @x;
  if (!defined $o || $o !~ /^\d+$/ || !defined $s || $s !~ /^\d+$/) { print STDERR "BADLINE $.: $_\n"; next; }
  my $dropit = ( ($off{$repo} && ($type eq 'blob' || $type eq 'tree'))
              || ($bo{$repo}  &&  $type eq 'blob')
              || ($dc{$repo}  &&  $type eq 'commit') );
  if ($dropit) { $drop++; next; }
  # oversized guard: drop objects too big to read in one go (convgen short-reads > ~2GB)
  if ($s > $MAXBLOB) { print STDERR "OVERSIZED $type drop repo=$repo o=$o s=$s (> $MAXBLOB)\n"; $drop++; $big++; next; }
  seek($BIN,$o,0); my $buf=''; my $got=0;   # robust read: loop until $s bytes (guards partial reads)
  while ($got < $s) { my $r=read($BIN,my $chunk,$s-$got); last if !defined $r || $r==0; $buf.=$chunk; $got+=$r; }
  die "short read repo=$repo o=$o s=$s got=$got\n" if $got != $s;
  print $OBIN $buf;
  $x[0] = $noff;
  print $OIDX join(';',@x)."\n";
  $noff += $s; $kept++;
}
close $OBIN; close $OIDX; close $IDX; close $BIN;
print STDERR "  [$type] kept=$kept dropped=$drop (oversized=$big) newbytes=$noff\n";
