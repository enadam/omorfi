#!/usr/bin/perl -w
#
# transltr.pl -- translate text using Google translate
#
# Synopsis:
#   transltr.pl <FROM-LANG>-<TO-LANG>	[<TEXT>] # SL->TL
#   transltr.pl <FROM-LANG>		[<TEXT>] # SL->en
#   transltr.pl  en			[<TEXT>] # en->fi
#   transltr.pl 			[<TEXT>] # fi->en
#

use strict;

use Encode;
use LWP;
use URI;
use HTTP::Request;
use HTML::Parser;

my ($sl, $tl, $text);

my $lang = qr/[[:lower:]][[:lower:]]/;
if (!@ARGV)
{	# Translate from Finnish.
	($sl, $tl) = qw(fi en);
} elsif ($ARGV[0] eq 'en')
{	# Translate to Finnish.
	($sl, $tl) = (shift, 'fi');
} elsif ($ARGV[0] =~ /^($lang)-($lang)$/)
{	# Translate between languages.
	($sl, $tl) = ($1, $2);
	shift;
} elsif ($ARGV[0] =~ /^$lang$/)
{	# Translate to English.
	($sl, $tl) = (shift, 'en');
} else
{	# Translate from Finnish.
	($sl, $tl) = qw(fi en);
}

if (@ARGV)
{
	$text = join(' ', @ARGV);
} else
{
	local $/ = undef;
	$text = <STDIN>;
}

$\ = "\n";
my $q = URI->new('http');
$q->query_form(sl => $sl, tl => $tl,
	ie => 'ISO-8859-1', text => encode('utf-8', $text));

my $rep = LWP::UserAgent->new()->request(
	HTTP::Request->new(POST => 'http://translate.google.com',
		[ 'User-Agent' => 'w3m/0.5.2' ], $q->query()));
$rep->is_success()
	or die $rep->status_list();

my $result;
HTML::Parser->new(
	api_version => 3,

	start_h => [ sub
	{
		my ($tag, $attrs) = @_;
		$result++ if $tag eq 'span'
			&& ($result || (defined $$attrs{'id'}
				&& $$attrs{'id'} eq 'result_box'));
	}, 'tagname,attr' ],

	end_h => [ sub
	{
		$result-- if $result && $_[0] eq 'span';
	}, 'tagname' ],

	text_h => [ sub
	{
		return if !$result;
		my $text = shift;
		$text =~ s//\n/g;
		print encode('iso-8859-2', $text);
	}, 'dtext' ])->parse($rep->content());

# End of transltr.pl
