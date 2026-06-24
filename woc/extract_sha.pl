while(<>){ chomp; for my $x (split /;/){ if($x =~ /^[0-9a-f]{40}$/){ print pack("H*",$x); last } } }
