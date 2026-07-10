#!/usr/bin/perl
# filterGenMinusBase.pl <dropShaFile> <genIdx> <genBin> <outIdx> <outBin>
#
# Rewrite a gen layer <type>_gen1 shard removing objects that are ALSO in the base
# (the irregular V2604->V2605 transition wrote ~734M base-overflow commits/trees into
# BOTH base and gen). dropShaFile = 40-hex shas to remove (typically gen ∩ base for the
# section). Streams genIdx in id order, byte-copies each KEPT record's bin range, and
# re-numbers id + re-offsets so the cleaned shard is self-consistent (gen-local offsets,
# 0-based) for CmtN2OffGen/TreeN2OffGen to re-map. idx line = id;off;len;sha.
#
# NO decompression -- pure byte copy of stored ranges (same discipline as filterDeoff.pl).
use strict; use warnings;
my ($dropf,$genIdx,$genBin,$outIdx,$outBin)=@ARGV;
die "usage: filterGenMinusBase.pl dropShaFile genIdx genBin outIdx outBin\n" unless $outBin;

my %drop;
open(my $D,'<',$dropf) or die "open $dropf: $!";
while(<$D>){ chomp; $drop{$_}=1 if /^[0-9a-f]{40}$/ } close $D;
my $ndrop = keys %drop;

open(my $I,'<',$genIdx)        or die "open $genIdx: $!";
open(my $B,'<:raw',$genBin)    or die "open $genBin: $!";
open(my $OI,'>',$outIdx)       or die "write $outIdx: $!";
open(my $OB,'>:raw',$outBin)   or die "write $outBin: $!";
my ($kept,$dropped,$noff,$bad)=(0,0,0,0);
while (<$I>) {
  chomp; my ($id,$off,$len,$sha)=split(/;/,$_,4);
  if (!defined $len || $off !~ /^\d+$/ || $len !~ /^\d+$/) { print STDERR "BADLINE $.: $_\n"; $bad++; next; }
  if ($drop{$sha}) { $dropped++; next; }
  seek($B,$off,0); my $buf=''; my $got=0;
  while ($got < $len) { my $r=read($B,my $c,$len-$got); last if !defined $r || $r==0; $buf.=$c; $got+=$r; }
  die "short read id=$id off=$off len=$len got=$got in $genBin\n" if $got != $len;
  print $OB $buf;
  print $OI join(';',$kept,$noff,$len,$sha)."\n";
  $noff += $len; $kept++;
}
close $OB; close $OI; close $I; close $B;
print STDERR "  [$genIdx] dropset=$ndrop kept=$kept dropped=$dropped bad=$bad newbytes=$noff\n";
# caller asserts: dropped == (gen records whose sha in dropset). kept = genN - dropped.
