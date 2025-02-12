#!/usr/bin/perl
use strict;
use warnings;
no warnings 'uninitialized';
use v5.20;

use constant DEBUG => 0;

use Scalar::Util qw(looks_like_number);
use Carp;
use Data::Dumper;

BEGIN{
	if(eval { require JSON::MaybeXS }){
		JSON::MaybeXS->import;
	} else {
		require JSON::PP;
		JSON::PP->import;
		eval "sub JSON { JSON::PP:: }";
	}
}

package Hash {
	sub AUTOLOAD:lvalue{
		$_ = our $AUTOLOAD;
		s/.*:://;
		my $a = shift;
		if(ref $a ne __PACKAGE__){
			#bless $#_?{@_}:shift;
			bless shift || {};
		}
		else {
			$$a{$_}
		}
	}
	sub TO_JSON{
		#say wantarray?"LIST":defined wantarray?"SCALAR":"VOID";
		#say STDERR "TO_JSON $#_ @_";
		no strict 'refs';
		${%$_[0]}
	}
}

my $data;
{
	open my $jfh, "<", "out.json";
	local $/ = undef;
	$data = <$jfh>;
	close $jfh;
}

my $json = decode_json $data;
open my $pfh, ">", "out.py";
open my $outfh, ">", "new.json";
open my $pyfh, ">", "py.json";
my $py = {};
#my $pyparent = $py;
my $lasttab;

my @sibs;
my %use;

my $line;
my $ARGV;
my $orig;
my $tablevel = 0;
my $offset;
my $hastest;
my $hasfmt;
my $lastval;
my $lastlevel = 0;
my $lastfmt;

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

my @plevel;
$plevel[0] = $py;
sub py {
	my $out = shift;
	#my $t = "\t" x $tablevel;
	my $pyparent;
	if($tablevel > $lasttab){
		#say "LVL $tablevel > $lasttab";
		$pyparent = $plevel[$lasttab];
#	}elsif($tablevel == $lasttab){
	}else{
		$pyparent = $plevel[$tablevel-1];
	}
	my $statement = {cond => $out, level => $tablevel};
	#say "XR ".ref($pyparent);
	#say "X statement ".ref($statement);
	#push @{ $pyparent->{zblock} }, ($statement);
	$plevel[$tablevel] = $statement;
	$lasttab = $tablevel;

	#say encode_json $py;
	my $t = " " x ($tablevel*4);
	say $pfh $t.$out;
}

sub dbg {
	if(DEBUG){
		my $msg = shift;
		py "# $msg";
	}
}

sub show {
	my $i = Hash->new(shift);
	my $parent = shift;
	my $sibs = shift;
	my %s = %{ $i };
	p($i, $sibs, $parent) unless $s{level} == 0;

	#say "$s{level} $s{yline}";
	my $f = $s{zzchild};
	if($f){
		$parent = $i;
		my @sibs;
		foreach my $ref (@{ $f }){
			#say "KID $ref";
			show($ref, $parent, \@sibs);
			push @sibs, ($ref);
		}
	}
}

# symbolically or numerically add two numbers
# symbols should go first, and will be returned first
sub add {
	my $a = norm(shift, 0);
	my $b = norm(shift, 0);
	my $dbg = "$a + $b";

	if(looks_like_number($a) && looks_like_number($b)){
		dbg "$dbg: add two numeric values";
		return $a + $b;
	}

	if(looks_like_number($a)){
		dbg "$dbg: 1st one is numeric, swapping";
		my $temp = $b;
		$b = $a;
		$a = $temp;
	}

	if(looks_like_number($b)){
		if($b == 0){
			dbg "$dbg: 2nd one is null";
			return $a;
		}
		# check if $a *ends* in a number
		elsif($a =~ / ([-+]) (\d+)$/){
			dbg "$dbg: composite";
			my $c = "$1$2";
			$c = "$2" if $1 eq '+';
			$a =~ s///;
			$b = add($c,$b);
			return add($a,$b);
		}
		elsif($b < 0){
			return "$a - ".abs($b);
		}
	}

	dbg "$dbg: default case";
	return "$a + $b";
}

sub p {
	my $s = shift;
	my $sibref = shift;
	my $parent = shift;
	my @sibs = @{ $sibref };
	my %struct = %{ $s }; # read-only
	my $predecessor = $sibs[-1] || $parent;

	my $level = $struct{level};
	$tablevel = $level - 1;
	my $type = $struct{type};
	my $numeric = $struct{numeric};
	my $orig = $struct{orig};
	my $offset = $struct{offset};
	my $hastest = $struct{hastest};
	my $hasfmt = int($struct{hasfmt});
	my $indirect = $struct{indirect};
	$line = $struct{yline};
	$ARGV = $struct{yfile};
	py "## $orig";

	my $preoff = 0;
	if($indirect){
		$preoff = add($predecessor->{calcoff}, $predecessor->{size}||0);
	}
	my $o;

	if($struct{indir}){ # $offset is a bunch of instructions
		my ($i,$pos,$type,$op,$extra) = split /;/,$struct{indir};
		$pos = norm($pos);
		if( ($op && !$extra) || (!$op && $extra) ){
			err "indir offset invalid extra param","$op $extra";
		}
		if($i){
			$pos = add($predecessor->{calcoff}, $pos);
		}
		
		$o = "unpack($pos,'$type')";
		if($op){
			$extra = norm($extra);
			if($op eq '+' || $op eq '-'){
				$op = '' if $op eq '+';
				$preoff = add($preoff, "$op$extra");
			}
			else {
				$o = "($o $op $extra)";
			}
		}
		$o = add($o,$preoff);
	}
	else {
		$o = add($preoff, norm($offset));
	}

	dbg "INDIRECT" if $indirect;
	if($struct{indir}){
		dbg "III $struct{indir}";
		#$o = "0:$struct{size}";
	}
	py "off = $o";
	$s->{calcoff} = $o;
	$s->{numoff} = looks_like_number($o);

	#if($struct{size} != -1){
		#$o .= ":".($o + $struct{size});
		#$o .= ":".($o + $struct{size});
	#}

	my $size = $struct{size} || 0;
	my $needval = $hastest && $struct{testtype} eq '';
	my $needfmt = $hasfmt || ($numeric && ($struct{testtype} ne '' || $struct{masktype} ne ''));
	my $valcnt = $s->{a_valcnt};
	my $fmtcnt = $s->{a_fmtcnt};
	my $hasdefault = $s->{a_hasdefault};
	my $parentdefault = $parent->{a_hasdefault};
	# XXX debug
	$valcnt = 0; $fmtcnt = 0;
	my $val;
	if($s->numoff){
		my $len = $o + $s->size;
		$val = "data[$o:$len]";
	}
	else {
		$val = "data[off:off+$struct{size}]";
	}
	my $valref = "val";
	$s->{a_val} = $val;
	if($level < $lastlevel){ # at top-level, to clear it in any case
		$lastval = '';
		$lastfmt = '';
	}
	if($needval){
		dbg "size $struct{size} val $val ne $lastval or $level <= $lastlevel";
		if($valcnt > 0){
			if($val ne $lastval){
				py "val = $val";
				$lastval = $val;
			}
			else {
				dbg "val saved";
			}
		}
		else {
			$valref = $val;
		}
	}
	my $fmt;
	if($numeric){
		$fmt = "unpack($o, '$struct{pyp}')";
	}
	else {
		$fmt = "string($o, $size)";
	}
	my $fmtref = "fmt";
	$s->{a_fmt} = $fmt;
	if($needfmt){
		dbg "size $struct{size} fmt $fmt ne $lastfmt or $level <= $lastlevel";
		if($fmtcnt > 0){
			if($fmt ne $lastfmt){
				py "fmt = $fmt";
				$lastfmt = $fmt;
			}
			else {
				dbg "fmt saved";
			}
		}
		else {
			$fmtref = $fmt;
		}
	}
	my $m = $struct{message};
	my $mime;
	$mime = "MIME ".$struct{mime} if $struct{mime};
	dbg "hastest:$hastest hasfmt:$hasfmt $ARGV:$line";
	$m =~ s/'/\\'/g;
	$m =~ s/(%[#0-9.]*)ll([a-z])($|[^a-z])/$1$2$3/;
	my $or = $orig;
	$or =~ s/\\/\\\\/g;
	$or =~ s/'/\\'/g;
	$or .= "\t#$ARGV:$line";
	$or = "$ARGV:$line";
	my $test = $struct{test};
	$test =~ s/\\/\\\\/g;
	$test =~ s/'/\\'/g;

	my $kids = $struct{zcnt} > 0;
	if($hastest){
		my $cond;
		if($struct{match} ne ''){
			$cond = "$valref == b'$struct{match}'";
		}
		elsif($struct{notmatch} ne ''){
			$cond = "$valref != b'$struct{notmatch}'";
		}
		elsif($numeric == 1){
			my $t = $struct{testtype};
			$t = "==" if $t eq '=';
			$t = "!=" if $t eq '!';
			$cond = "$fmtref $struct{masktype} $struct{mask} $t $struct{test}";
			$cond =~ s/ +/ /g;
			$cond =~ s/ != 0$//;
		}
		else {
			$cond = "missing('$struct{type}', '$test')";
		}
		my $action = "pass";
		if($hasfmt){
			 $action = "display('$m', '$mime', $fmtref, '$or')";
		}
		#elsif($m ne ''){
		#	$action = "match('$m', '$or')"; 
		#}
		elsif($m || $parentdefault || $mime){
			#$action = "pass";
			# if there's a default action
			dbg "match $m || $parentdefault || $mime";
			$action = "match('$m', '$mime', '$or')"; 
		}
		if($kids){
			py "if $cond:";
			$tablevel++;
			py "$action" unless $action eq 'pass';
		}
		elsif($action ne 'pass'){
			py "if $cond:";
			$tablevel++;
			py "$action";
		}
		if($hasdefault){
			py "clear() # test hasdef"
		}
		$s->{a_action} = $action;
		$s->{a_cond} = $cond;
	}
	else {
		dbg "NOTEST class:$struct{class} type:$type";
		my $cond = "True";
		my $action = "pass";
		if($hasfmt){
			py "display('$m', '$mime', $fmtref, '$or')";
		}
		elsif($type eq 'default'){
			py "# SETDEFAULT $or $parent->{orig}";
			$parent->{a_hasdefault} = 1;
			$cond = "nomatch('$or')";
			if($m ne ''){
				$action = "match('$m', '$or')";
			}
			else {
				$action = "pass";
			}
		}
		elsif($type eq 'use'){
			my $t = $struct{test};
			my $flip = 0;
			if($t =~ /^\\\^/){
				$flip = 1;
				$t =~ s///;
			}
			$action = "use('$t', $flip)";
			$use{$t}{cnt}++;
		}
		elsif($type eq 'lestring16'){
			$action = "missing('$struct{type}', '$test')";
		}
		elsif($type eq 'der'){
			$action = "missing('$struct{type}', '$test')";
		}
		elsif($type eq 'name'){
			$action = "missing('$struct{type}', '$test')";
			$use{$test}{orig} = "$or";
		}
		elsif($numeric && ($m || $parentdefault || $mime)){
			#$cond = 'True';
			$cond = "match('$m', '$or')"; 
		}
		else {
			$cond = "missing('$struct{type}', '$test')";
			#err "NO COND", $or;
		}

		my $clear = 1;
		$clear = 0 if $hasdefault;
		if($hasdefault and $cond eq 'True'){
			$cond = 'clear()';
			$clear = 1;
		}

		#say "XX $line";
		#my $sga = "foo $line";
		#py "print('$sga')";
		#dbg "YYY $line $cond $kids $action # $or $line $struct{yline}";
		if($kids or (($action ne 'pass') and ($cond ne 'True'))){
		#if(($cond ne 'True' and !$kids) or ($action ne 'pass')){
			py "if $cond:";
			$tablevel++;
		}
		py "$action" unless $action eq 'pass';
		py "clear() # notest" unless $clear;
		$s->{a_action} = $action;
		$s->{a_cond} = $cond;
	}
	if($mime){
		py "mime('$mime')";
	}

	if( $parent->{a_val} eq $s->{a_val} ){
		$parent->{a_valcnt}++;
		#say "val++ p from $s->{yline} to $parent->{yline}";
	}
	if( $parent->{a_fmt} eq $s->{a_fmt} ){
		$parent->{a_fmtcnt}++;
		#say "fmt++ p from $s->{yline} to $parent->{yline}";
	}
	foreach my $ref (@sibs){
		if( $ref->{a_val} eq $s->{a_val} ){
			$ref->{a_valcnt}++;
			#say "val++ s from $s->{yline} to $ref->{yline}";
		}
		if( $ref->{a_fmt} eq $s->{a_fmt} ){
			$ref->{a_fmtcnt}++;
			#say "fmt++ s from $s->{yline} to $ref->{yline}";
		}
	}
	$s->{a_level} = $level;

	$lastlevel = $level;
}

show $json;
open $pfh, ">", "out2.py";
show $json;

my $j = JSON->new->convert_blessed;
#say Dumper \%use;
say $j->encode(\%use);
print $outfh $j->encode($json);
print $pyfh $j->encode($py);
