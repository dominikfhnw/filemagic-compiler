#!/usr/bin/perl
use warnings;
no warnings 'uninitialized';
no warnings 'portable';	# hex() and oct() with 64bit values
			# bigint would solve it, but is very slow to load
no warnings 'pack';	# values too big
use strict;
use v5.20;
use Data::Dumper;

our $true;
our $false;
BEGIN{
	no warnings 'once';
        if(eval { require JSON::MaybeXS }){
		say "using json::xs";
                JSON::MaybeXS->import;
		$true = JSON()->true;
		$false = JSON()->false;

        } else {
		say "using json::pp";
                require JSON::PP;
                JSON::PP->import;
		$true = $JSON::PP::true;
		$false = $JSON::PP::false;
        }
}
#use YAML::PP;
use Carp;

my $debug = 1;
my $normstring = 0;
my $normoffset = 0;
my $peephole = 1;
my $numcheck = 0;

our $line = 0;
our $ARGV;
our $orig;

my %a;
$a{class} = "empty";
$a{zzchild} = ();
$a{offset} = 0;
my $last = \%a;
my $lastlevel = 0;
my $parent = \%a;
my @plevel;
$plevel[0] = \%a;
my $lastfile = $ARGV;
my $lastline = 0;
my $tablevel = 0;
# reuse python statements
my $lastval;
my $lastfmt;

sub dbg {
	say @_ if $debug;
}

sub dbe {
	if($debug){
		say @_, "\t#$ARGV:$line";
	}
}

sub err {
	my $msg = shift;
	my $val = shift;

	carp "ERROR: $msg, ($val) in $ARGV:$line\n\torig: $orig";
}

sub numeric {
	my $num = shift;
	if($num !~ /^-?(0[0-7]*|0x[0-9a-fA-F]+|[0-9]+|[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?)$/){
		err "not a number", $num;
	}
}

sub norm {
	my $num = shift;
	my $test = shift;
	$test = 1 if $test eq '';
	numeric($num) if $test;
	$num = oct($num) if $num =~ /^-?0/;
	$num = int($num) if $num =~ /^-?\d/;
	return $num;
}

sub unescape {
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
		if (/[\\']/){
			$out .= '\\x'.(sprintf "%02x",ord);
			#$out .= "\\$1";
		}
		elsif (/[ -~]/){
			$out .= $_;
		}
		else {
			my %e = (7, 'a', 8, 'b', 9, 't', 10, 'n', 11, 'v', 12, 'f', 13, 'r');
			#my %e = (8, 'b', 9, 't', 10, 'n', 12, 'f', 13, 'r'); # as allowed by json
			my $ord = ord;
			if($e{$ord}){
				#say "ORD";
				$out .= '\\'.$e{$ord};
			}
			elsif ($ord < 64 and $next !~ /[0-7]/) {
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

open our $pfh, '>', "out.py";

sub py {
	my $line = shift;
	#my $t = "\t" x $tablevel;
	my $t = " " x $tablevel;
	say $pfh  $t.$line;
}

while(<>){
	if($ARGV ne $lastfile){
		$line = 0;
		$lastfile = $ARGV
	}
	$line++;
	chop;
	$orig = $_;
	my %struct;
	my $numeric;
	if(/^(#|$)/){
		say;
		py $_;
		next;
	}

	if(/^!:(ext|apple|strength|mime)\s+(.*)$/){
		my $opt = $1;
		my $val = $2;
		my $comment = "";
		if($val =~ /#\s*(.*)\s*$/){
			$comment = $1;
			$val =~ s/\s*#.*$//;
			#say "# $comment";
		}
		
		my @a = split /\s+/, $val;
		$_ = join " ",@a;
		if($opt eq "strength"){
			die "uhoh $_" if scalar(@a) > 2;
		}else {
			die "uhoh $_" if scalar(@a) > 1;
		}
		${ $last }{$opt} = $val;
		say;
		next;
	}

	if(/^(>+&?)*(-?[0-9]|\()/){
		/^(>*)(&?)/;
		my $level = 1 + length $1;
		$tablevel = 0 + length $1;
		$struct{level} = $level;
		my $indirect = 0;
		if($2 eq '&'){
			$indirect = 1;
			$struct{indirect} = $true;
		}
		dbg "LEVEL $level INDIRECT $indirect";
		s///;

		#say "- $_";
		/^(\S+)\s+(\S+)\s+(\S+)(?:\s+(.*))?/;
		my ($offset, $type, $test, $message) = ($1,$2,$3,$4);
		my ($flags, $mask, $endian, $unsigned, $prefix);
		$unsigned = 0;
		$endian = 0;
		my $masktype;
		my $testtype;
		my $hastest = 0;
		my $hasfmt = 0;
		dbg "OFFSET $offset";
		if($offset =~ /^\(/){
			if($offset =~ /^\((\&?)(-?[0-9a-fA-Fx]+)(?:.([bBcCeEfFgGhHiIlLmsSqQ]))?(?:([-+*\&\/])([-()0-9a-fA-Fx]+))?\)$/){
				my $indir = $1 eq '&' ? 1 : 0;
				my $o = $2;
				my $t = $3 || 'l';
				my $op = $4;
				my $x = $5;
				if($x =~ /^\((.*)\)$/){
					$x = $1;
				}
				numeric($o);

				numeric($x) if $x ne "";
				# TODO ugly
				$struct{indir} = "$indir;$o;$t;$op;$x";
				dbg "INDIR $offset -- $indir $o $t $op $x";
				dbg "IOP $t";
			}
			else {
				err "invalid indirect offset", $offset;
			}
		}
		else {
			numeric($offset);
			$offset = norm($offset) if $normoffset;
		}
		$struct{offset} = norm($offset,0);
		my $o2 = $orig;
		$o2 =~ s/\t/    /g;
		#$struct{orig} = $o2; #. "\t#$ARGV:$line";
		$struct{yfile} = $ARGV;
		$struct{yline} = $line;


		dbg "OFFSET2 $offset";

		dbg "TYPE0 $type";
		if($type =~ m!(/[a-zA-Z0-9/]+)$!){
			$flags = $1;
			$struct{flags} = $flags;
			dbg "FLAGS $flags";
			$type =~ s///;
		}

		if($type =~ m!([\&\%\+\^\|\-\*])([0-9xa-fA-F]+)$!){
			$masktype = $1;
			$mask = $2;
			$struct{masktype} = $1;
			$struct{mask} = norm($mask);
			numeric($mask);
			dbg "MASK $masktype $mask";
			$type =~ s///;
		}

		if($mask ne "" and $flags ne ""){
			err "flag and mask on same line","$mask $flags";
		}

		if($message =~ /%./){
			$hasfmt = 1;
		}

		if($type =~ m!^(p?string|regex|search)$!){
			if($mask ne ""){
				err "mask on invalid type", $mask;
			}
			$hastest = 1;
			dbg "XFL $flags $type";
			s/\\ /\xff/g;
			# TODO: duplicated regex
			/^(\S+)\s+(\S+)\s+(\S+)(?:\s+(.*))?/;
			($test, $message) = ($3,$4);
			$test =~ s/\xff/\\ /g;
			$test = escape(unescape($test)) if $normstring;
			if($hasfmt and $type eq "string"){
				dbe "STRF $message -- $orig";
			}
			if($type eq 'string'){
				if($test eq 'x'){
					$hastest = 0;
					$struct{size} = 60;
				}
				elsif($test eq '>\0'){
					$hastest = 0;
					$struct{size} = 60;
				}
				elsif($test =~ m{^([\Q<>!=\E])(.+)$}){
					$testtype = $1;
					$test = $2;
					dbe "AAAA $hasfmt $test -- $orig";
					$struct{size} = length unescape $test;
				}
				else {
					$testtype = '=';
					$struct{size} = length unescape $test;
				}
				if($testtype eq '='){
					if($hasfmt){
						$message = sprintf($message, $test);
						$hasfmt = 0;
						dbg "SUSP -- $orig";
					}
					$struct{match} = escape(unescape($test)) if $flags eq '';
				}
				elsif($testtype eq '!'){
					$struct{notmatch} = escape(unescape($test)) if $flags eq '';
				}
			}	
			$message =~ s/\xff/\\ /g;
		}
		# TODO: orphaned names
		elsif ($type =~ /^(use)$/){
			if($test !~ /^(\\\^)?([a-zA-Z0-9][-_a-zA-Z0-9]+)$/){
				# switch endiannes if first char is ^
				err "invalid test in use",$test;
			}
			if($mask ne ""){
				err "mask on invalid type", $mask;
			}
			if($flags ne ""){
				err "flags on invalid type", $flags;
			}
		}
		elsif ($type =~ /^(name)$/){
			if($test !~ /^([a-zA-Z0-9][-_a-zA-Z0-9]+)$/){
				err "invalid test in name",$test;
			}
			if($mask ne ""){
				err "mask on invalid type", $mask;
			}
			if($flags ne ""){
				err "flags on invalid type", $flags;
			}
			if($offset ne "0"){
				err "invalid offset", $offset;
			}
			#dbg "NAME $test $offset -- $orig";
			#delete $struct{offset};
		}
		elsif ($type =~ /^(indirect)$/){
			if($mask ne ""){
				err "mask on invalid type", $mask;
			}
			if($test ne "x"){
				err "invalid test in indirect",$test;
			}
			dbe "INDIRECT -- $flags -- $orig";
			$hastest = 1;
		}
		elsif ($type =~ /^(default|clear)$/){
			if($test ne "x"){
				err "invalid test",$test;
			}
			if($mask ne ""){
				err "mask on invalid type", $mask;
			}
			if($flags ne ""){
				err "flags on invalid type", $flags;
			}
		}
		elsif ($type =~ /^(offset|der|guid|lestring16|bestring16)$/){
			if($mask ne ""){
				err "mask on invalid type", $mask;
			}
			if($flags ne ""){
				err "flags on invalid type", $flags;
			}
		}
		else {
			if($type =~ /^u/){
				$unsigned = 1;
				$struct{unsigned} = $true;
				$type =~ s///;
				$prefix = "u";
			}
			if($type =~ /^be/){
				$endian = 1;
				$struct{endian} = 'big';
				$type =~ s///;
				$prefix .= "be";
			}elsif($type =~ /^le/){
				$endian = 0;
				$struct{endian} = 'little';
				$type =~ s///;
				$prefix .= "le";
			}
			dbg "DTYPE $unsigned $endian";

			# yay, reusing the same character that specified a flag....
			if($flags =~ m!^/([0-9a-fA-Fx]+)$!){
				$flags = '';
				delete $struct{flags};
				$masktype = '/';
				$mask = $1;
				$struct{mask} = $mask;
				$struct{masktype} = $masktype;
			} elsif($flags ne "") {
				err "wrong flags on type", $flags;
			}

			# TODO: refactor
			if($test !~ m{^([\Q<>!&^=\E]?)(-?[0-9xa-fA-F]+)$}){
				if($type eq 'double' or $type eq 'float'){
					if($test !~ m{^([\Q<>!&^=\E]?)(-?[-+0-9eE.]+)$}){
						err "invalid test", $test;
					}
					$testtype = $1; #|| "=";
					$test = $2;
				}
				else {
					err "invalid test", $test;
				}
			}
			else {
				$testtype = $1; #|| "=";
				$test = $2;
			}

			if($testtype eq '&' or $testtype eq '^'){
				#err "deprecated test type", $testtype;
			}
			my %ptype = (
				'quad' => 'q', 'short' => 's', 'long' => 'l', 'byte' => 'c',
				'date' => 'l', 'ldate' => 'l', 'qdate' => 'q', 'qldate' => 'q',
				'double' => 'd', 'float' => 'f',
				'medate' => 'l', 'qwdate' => 'q', # XXX: this is all wrong
			);
			my %perl2py = ( 'c' => 'b', 's' => 'h');
			my $pack = $ptype{$type};
			# TODO: refactor
			my $packtype = $pack;
			my $pypack = $pack;
			if($perl2py{$pack}){
				$pypack = $perl2py{$pack};
			}
			$pypack = uc($pypack) if $unsigned;
			err "no pack", $type if $pack eq '';
			$pack = uc($pack) if $unsigned;
			#$pack .= ($endian ? '>' : '<') if $type ne 'byte';
			my $end = ($endian ? '>' : '<') if $type ne 'byte';
			$pack .= $end;
			$pypack = "$end$pypack";
			$struct{pyp} = $pypack;
			dbg "PACK $pack -- $orig";
			my $packed = pack($pack,0);
			$struct{size} = length $packed;

			if($test ne "x"){
				numeric($test);
				my $num = norm $test;
				my $packed = pack($pack,$num);
				if($peephole and $testtype eq '>' and $num == 0 and $unsigned){
					dbg "PEEPHOLE -- $orig";
					$testtype = '!';
				}
				$hastest = 1;
				$struct{testtype} = $testtype || '=';
				if($peephole and $hasfmt and ($struct{testtype} eq '=')){
					if($masktype eq ""){
						$message = sprintf($message, $num);
						$hasfmt = 0;
					}
					elsif($masktype eq "&"){
						$message = sprintf($message, $num & norm($mask));
						$hasfmt = 0;
					}
					else {
						err "peephole op not implemented", $masktype;
					}
					dbg "SUSP $num $mask $message -- $orig";
				}
				if($numcheck){
					if($packtype eq 'c' and $num > 2**7-1){
						err "value does not fit", $num;
					} elsif($packtype eq 'C' and $num > 2**8-1){
						err "value does not fit", $num;
					} elsif($packtype eq 's' and $num > 2**15-1){
						err "value does not fit", $num;
					} elsif($packtype eq 'S' and $num > 2**16-1){
						err "value does not fit", $num;
					} elsif($packtype eq 'l' and $num > 2**31-1){
						err "value does not fit", $num;
					} elsif($packtype eq 'L' and $num > 2**32-1){
						err "value does not fit", $num;
					} elsif($packtype eq 'q' and $num > 2**63-1){
						err "value does not fit", $num;
					} elsif($packtype eq 'Q' and $num > 2**64-1){
						err "value does not fit", $num;
					} elsif($num < 0){
						#err "neg?", $num;
					}
				}
				if($masktype eq ''){
					if($struct{testtype} eq '='){
						$struct{match} = escape $packed;
					}
					elsif($struct{testtype} eq '!'){
						$struct{notmatch} = escape $packed;
					}
				}


			}
			else {
				$testtype = '';
			}
			#$struct{test} = norm($test);
			dbg "TTYPE $testtype";
			dbg "TTP $testtype -- $test";

			if($masktype ne '' and $masktype ne '&'){
				dbe "MSK2 $type $masktype $mask $test $message -- $orig";
			}
			dbg "X $type $unsigned $endian $testtype $test $flags $masktype $mask";
			dbg "TEST $test";
			dbg "OTHERTYPE $type";
			dbe "PPP $test -- $orig";
			$numeric = 1;
			$struct{numeric} = $numeric;
		}
		dbg "TYPE $type";
			
		if($numeric){
			$struct{test} = norm($test) if $test ne 'x';
		}
		else {
			$struct{test} = $test if $test ne 'x';
		}
		if($testtype){
			$struct{testtype} = $testtype;
		}
		$struct{type} = $type;

		if($message ne ''){
			my $m2 = $message;
			if($m2 =~ /^\\b/){
				$m2 =~ s///;
			}
			elsif( $level == 1 ){
				$m2 = $m2;
			}
			else {
				$m2 = " $m2";
			}
			# can happen when the message is just '\b'
			if($m2 ne ''){
				$struct{message} = $m2;
			}
		}

		#if ($type =~ /^(default|indirect|use|name|offset|clear)$/){
		#	dbe "TX $type $test $message" if $message ne "";
		#}
		#say "+ $offset\t$type$flags\t$test\t$message";
		#my $hastest = $test eq "x"?0:1;
		#if(!$fmt 

		###
		### CLASSIFICATION OF RULES
		###

		if($hasfmt){
			if(!$hastest){
				dbg "MT DISPLAYONLY";
				dbg "XM $orig";
				$struct{class} = "display";
			}
			else {
				dbg "MT BOTH";
				$struct{class} = "both";
			}
		} else {
			if(!$hastest){
				dbg "MT EMPTY?";
				$struct{class} = "empty";
				#if($type !~ /use|default|name|offset/){
					dbe "MX $type $test $message";
				#}
			}
			else {
				dbg "MT TEST";
				$struct{class} = "test";
				if($masktype ne "" and $masktype ne '&'){
					dbe "MD $type $masktype $mask $test $flags $message -- $orig x";
				}
			}
		}

		if($struct{match} ne ''){
			$struct{class} = "match";
			delete $struct{endian};
			delete $struct{unsigned};
			delete $struct{test};
			delete $struct{testtype};
			#delete $struct{type};
		}
		if($struct{notmatch} ne ''){
			$struct{class} = "notmatch";
			delete $struct{endian};
			delete $struct{unsigned};
			delete $struct{test};
			delete $struct{testtype};
			#delete $struct{type};
		}
		
		###
		### PYTHON CODE GENERATION
		###

		#my $o = $offset eq 0 ? '' : norm($offset, 0);
		my $o = norm($offset, 0);
		if($struct{size} != -1){
			$o .= ":".($o + $struct{size});
		}
		py "# INDIRECT" if $indirect;
		if($struct{indir}){
			py "# III $struct{indir}";
			$o = "0:1";
		}
		py "## $orig";
		#py "# class $struct{class} type $struct{type}";
		my $valchange = 0;
		#if($struct{type} eq 'string' or $numeric){
		#if($hasfmt or ($numeric and $struct{testtype} ne '')){
		if($hastest or $hasfmt){
			my $val = "data[$o]";
			if($val ne $lastval or $level < $lastlevel){
				#py "# val $val ne $lastval or $level <= $lastlevel";
				py "val = $val";
				$lastval = $val;
				$valchange = 1;
			}
		}
		my $fmt;
		if($numeric){
			$fmt = "unpack('$struct{pyp}', val)";
		}
		else {
			$fmt = "val.decode('latin1')";
		}
		if($hasfmt or ($numeric and $struct{testtype} ne '')){
			if($level < $lastlevel or ($valchange) or ($fmt ne $lastfmt)){
			#if($valchange and $fmt and ($fmt ne $lastfmt or $level < $lastlevel)){
				py "fmt = $fmt";
				$lastfmt = $fmt;
			}
		}
		my $m = $struct{message};
		$m =~ s/'/\\'/g;
		#$m =~ s/(%[#0-9.]*)ll([a-z])($|[^a-z])/\1\2\3/;
		my $or = $orig;
		$or =~ s/\\/\\\\/g;
		$or =~ s/'/\\'/g;
		$or .= "\t#$ARGV:$line";
		$or = "$ARGV:$line";
		if($hastest){
			my $cond;
			if($struct{match} ne ''){
				$cond = "val == b'$struct{match}'";
			}
			elsif($struct{notmatch} ne ''){
				$cond = "val != b'$struct{notmatch}'";
			}
			elsif($numeric == 1){
				my $t = $struct{testtype};
				$t = "==" if $t eq '=';
				$t = "!=" if $t eq '!';
				$cond = "fmt $struct{masktype} $struct{mask} $t $struct{test}";
			}
			else {
				$cond = "False";
			}
			py "if $cond:";
			$tablevel++;
			if($hasfmt){
				py "display('$m', fmt, '$or')";
			}
			elsif($m ne ''){
				py "match('$m', '$or')"; 
			}
			else{
				py "pass";
			}
		}
		else {
			py "# NOTEST class:$struct{class} type:$type";
			my $cond = "True";
			my $action = "pass";
			if($hasfmt){
				py "display('$m', fmt, '$or')";
			}
			elsif($type eq 'default'){
				$cond = "nomatch('$or')";
				if($m ne ''){
					$action = "match('$m', '$or')";
				}
				else {
					$action = "pass";
				}
			}
			elsif($numeric){
				$cond = 'True';
				$action = "match('$m', '$or')"; 
			}
			else {
				$cond = "unclear()";
				#err "NO COND", $or;
			}

			if($cond){
				py "if $cond:";
				$tablevel++;
			}
			py "$action";
		}

		###
		### LINTED OUTPUT
		###

		$struct{hasfmt} = $hasfmt;
		$struct{hastest} = $hastest;
		$struct{numeric} = $numeric;
		$struct{orig} = $orig;
		dbg "MSG $hasfmt $hastest $masktype";
		my $l = ">" x ($level-1);
		my $i = $indirect ? '&' : '';
		say "$l$i$offset\t$prefix$type$flags$masktype$mask\t$testtype$test\t$message";
		#say "O:$offset,T:$type,X:$test,M:$message";
		#say "";
		dbg "STRUCT $level $last";
		if($level > $lastlevel){
			dbg "JS $level > $lastlevel";
			$parent = $plevel[$lastlevel];
		}
		elsif($level == $lastlevel){
			dbg "JS $level == $lastlevel";
	
		}
		else {
			dbg "JS $level < $lastlevel";
			dbg "JJ I am at level $level. It was $lastlevel before. My parent is at level ".($level-1);
			$parent = $plevel[$level-1];
			dbg "JSUP $parent";
		}

		push @{ ${ $parent }{zzchild} }, \%struct;
		${ $parent }{zcnt}++;
#		if($debug){
#			dbg "GLOB ".encode_json \%a;
#			dbg "MYSELF ".encode_json \%struct;
#			dbg "PARENT ".encode_json $parent;
#		}
		#say "LAST ".encode_json $last;
		$plevel[$level] = \%struct;
		$last = \%struct;
		$lastlevel = $level;
		next;
	}

	die "unknown line $line: $_\n";
}

warn "serializing";
#open my $yfh, '>', "out.yaml";
#my $yp = YAML::PP->new(
#	schema => [qw/ + Perl /],
#	boolean => 'JSON::PP',
#	header => 0,
#);
#$yp->dump_file("out.yaml", $a{zzchild}) || die "yaml err";
open my $jfh, '>', "out.json";
print $jfh encode_json \%a;
close $jfh;
