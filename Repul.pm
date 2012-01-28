package Repul;
use strict;

my %HunTbl =
(
	"a'" => '�',
	"A'" => '�',
	"e'" => '�',
	"E'" => '�',
	"i'" => '�',
	"I'" => '�',
	"u'" => '�',
	"U'" => '�',

	"u:" => '�',
	"U:" => '�',

	'o"' => '�',
	'O"' => '�',
	'u"' => '�',
	'U"' => '�',
);

sub repul
{
	$_ = shift;

	s/::|:([ao]+)|([ao]+):(?!:)/{
		my $x = $^N;
		defined $x
			? $x =~ tr!aAoO!����!
			: $x = ':';
		$x;
	}/ige;
	s/(@{[join('|', keys(%HunTbl))]})/$HunTbl{$1}/ge;
	s/\\(.)/$1/g;

	return $_;
}

if (0)
{
	die unless repul('aa:') eq '��';
	die unless repul(':aa') eq '��';

	die unless repul(':a::a:') eq '�:�';
	die unless repul(':a:::a') eq '�:�';
	die unless repul('a::a:')  eq 'a:�';
	die unless repul('a:::a')  eq 'a:�';
	die unless repul(':a::a')  eq '�:a';
	die unless repul('a::a')   eq 'a:a';

	die unless repul(':a:::a:::a') eq '�:�:�';
	die unless repul(':a:::a::a:') eq '�:�:�';
	die unless repul('a:::a:::a')  eq 'a:�:�';
	die unless repul('a:::a::a:')  eq 'a:�:�';
	die unless repul(':a::a:::a')  eq '�:a:�';
	die unless repul(':a::a::a:')  eq '�:a:�';
	die unless repul('a::a:::a')   eq 'a:a:�';
	die unless repul('a::a::a:')   eq 'a:a:�';
	die unless repul(':a:::a::a')  eq '�:�:a';
	die unless repul('a:::a::a')   eq 'a:�:a';
	die unless repul(':a::a::a')   eq '�:a:a';
	die unless repul('a::a::a')    eq 'a:a:a';
}

1;
