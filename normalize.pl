#!/usr/bin/perl
use warnings;
no warnings 'uninitialized';
use strict;
use v5.20;

use bigint qw(oct);
 
sub expand_escapes {
  local $_ = shift;
  s{
    (
      \\
      (?:
        x[A-Fa-f0-9]{0,2}  # hex escape
        |
        [0-7]{1,3}        # octal escape
        |
        .                  # any other
      )
    )
  }{qq["$1"]}geexs;
  return $_;
} 

sub escape {
	my $in = shift;
	my $out;
	my $i = 1;
	for (split //, $in){
		my $next = substr($in, $i, 1);
		if (/[\\]/){
			$out .= '\\x'.(sprintf "%02x",ord);
		}
		elsif (/[ -~]/){
			$out .= $_;
		}
		else {
			my %e = (7, 'a', 8, 'b', 9, 't', 10, 'n', 11, 'v', 12, 'f', 13, 'r');
			my $ord = ord;
			if($e{$ord}){
				#say "ORD";
				$out .= '\\'.$e{$ord};
			}
			elsif ($ord < 64 and $next !~ /[0-9]/) {
				#say "NEXT small";
				$out .= '\\'.(sprintf "%o",ord);
			}
			else {
				$out .= '\\x'.(sprintf "%02x",ord);
			}
		}
		$i++;
	}

	return $out;
}

my $debug = 1;
while(<>){
	chomp;
	my ($a, $b, $c, $off,$cmd,$test,$desc,$d) = split /;/,$_,8;
	say "> $off\t$cmd\t$test\t$desc" if $debug;
	$desc =~ s/,$//;
	$off = oct($off) if $off =~ /^0/;
	if($cmd eq "string/b"){
		$cmd = "string";
	}
	if($cmd eq "string/f"){
		$cmd = "string";
	}
	if($cmd ne "string"){
		$test =~ s/^=//;
		say "X $test" if $debug;
		$test = oct($test) if $test =~ /^0/;
	}
	else {
		my $b = expand_escapes($test);
		my $t2 = $test;
		$t2 =~ s!\\ ! !g;
		my $c = qx!/usr/bin/printf -- "$t2"!;
		if($b ne $c){
			say "ESCAPE ERR $test";
			#say $a;
			say $b;
			say $c;
			#$a =~ s/(.)/sprintf '%02x ', ord $1/seg;
			$b =~ s/(.)/sprintf '%02x ', ord $1/seg;
			$c =~ s/(.)/sprintf '%02x ', ord $1/seg;
			#say $a;
			say $b;
			say $c;
		}
		$test = escape(expand_escapes($test));
	}

	my $u = 0;
	if($cmd =~ /^u/){
		$u = 1;
		$cmd =~ s/^u//;
	}

	if($cmd =~ /belong&(0xffffff00|&077777777)$/){
		$test = escape(substr(pack("L>", $test),0,3));
		$cmd = "string";
	}

	if($cmd =~ /(le)?long&(0xffffff00|&077777777)$/){
		$test = escape(substr(pack("L<", $test),0,3));
		$cmd = "string";
	}


	my $e = "<";
	if($cmd =~ /^be/){
		$e = ">";
		$cmd =~ s/^be//;
	}
	if($cmd =~ /^le/){
		$e = "<";
		$cmd =~ s/^le//;
	}
	
	if($cmd =~ /short$/){
		$test = escape(pack("S$e", $test));
		$cmd = "string";
	}

	if($cmd =~ /long$/){
		$test = escape(pack("L$e", $test));
		$cmd = "string";
	}

	if($cmd =~ /quad$/){
		$test = escape(pack("Q$e", $test));
		$cmd = "string";
	}

	if($cmd eq "search/1"){
		$cmd = "string";
		my $ot = $off + 1;
		say "$ot;$cmd;$test;$desc";
	}

	say "< $off\t$cmd\t$test\t$desc" if $debug;
	say "" if $debug;
	say "$off;$cmd;$test;$desc" unless $debug;
}
