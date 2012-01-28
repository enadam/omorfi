#!/usr/bin/perl -w
#
# Invocation:
#   omorfi.pl [-ANcam] [-<abrv>:<transducer>]...
#
# The switches affect which transducers to load on startup.  Loading takes some
# time, so by default only the colorterm transducer is loaded, and the others
# are loaded on demand.
#
# hfst-proc and the transducers are best if they are in the same directory as
# the script, but they can also be in other directories.
#
# Usage:
# omorfi> vihannes			# your input
#         vihannesNSgNom		# the analysis (in color)
# omorfi> vihanneksen
#         vihannesNSgGen
# omorfi> A: vihannes			# select Apertum format output
#         vihannes<N><Sg><Nom>		# which doesn't use colors
# omorfi> g: vihannes<N><Pl><Gen>	# now generate the plural genitive
#         vihanneksien
#         vihannesten
# omorfi> :aitisi			# you can use ':' to spell accented
#         äitiNPlNomSg2			# characters if you don't want to change
#         äitiNSgGenSg2			# your keyboard settings
#         äitiNSgNomSg2
# omorfi> [Pekka voi antaa lis:aa ruokaa.]	# use transltr.pl to
# Pekka can provide more food.			# translate the sentence
# omorfi>
#

use strict;
use Socket;
use Errno qw(EINTR EADDRINUSE);
use POSIX qw(:sys_wait_h);
use Encode;
use Storable;
use IPC::Open3;
use Term::ReadLine;
use Repul;

### IPC ###
sub ipc_init
{
	my $which = shift;

	my $me = 'omorfi';
	my $server = sockaddr_un("\0$me");

	socket(SOCK, PF_UNIX, SOCK_DGRAM, PF_UNSPEC)
		or die "socket: $!";
	if (!defined $which || $which eq 'server')
	{	# Is the server already running?
		if (bind(SOCK, $server))
		{	# Start the server.
			my $pid = fork();
			if (!defined $pid)
			{
				warn "fork: $!";
				return 0;
			} elsif (!$pid)
			{
				setpgrp(0, 0);
				exit server();
			} else
			{	# Server started, now connect the client.
				close(SOCK);
				return ipc_init('client');
			}
		} elsif ($! != EADDRINUSE)
		{
			warn "bind($me): $!";
			return 0;
		} elsif (defined $which && $which eq 'server')
		{	# Server was already running, return if starting it
			# all we had to do.
			return 1;
		}
	}

	# We are the client, connect to the server.
	connect(SOCK, $server)
		or die "connect($me): $!";
	for (;;)
	{	# Try until we find an unused client address.
		my $client = "${me}_client." . rand();
		return 1 if bind(SOCK, sockaddr_un("\0$client"));
		warn "$client: $!";
		return 0 unless $! == EADDRINUSE;
	}
}

sub ipc_get_msg
{
	my ($sender, $msg);

	# Only the server is interested in the sender in order to know
	# where to send the reply.
	my $otherside = wantarray ? "client" : "server";
	while (!defined ($sender = recv(SOCK, $msg, 10240, 0)))
	{	# SIGCHLD may interrupt us.
		if ($! != EINTR)
		{
			warn "recv($otherside): $!";
			return undef;
		}
	}

	if (!defined ($msg = Storable::thaw($msg))
		|| ref($msg) ne 'ARRAY' || !@$msg || !defined $$msg[0])
	{	# The message should always be a non-empty array.
		warn "malformed message from $otherside";
		return undef;
	}

	return wantarray ? ($sender, $msg) : $msg;
}

# msg: client -> server
sub ipc_request
{
	if (!send(SOCK, Storable::freeze(\@_), 0))
	{
		warn "send(server): $!";
		return 0;
	}
	return 1;
}

# msg: server -> client
sub ipc_reply
{
	my $dest = shift;
	if (!send(SOCK, Storable::freeze(\@_), 0, $dest))
	{
		warn "send(client): $!";
		return 0;
	}
	return 1;
}

sub ipc_ready
{
	return ipc_reply(shift, 'ok', @_);
}

### Server ###
# Tell the client to be with some patience.
sub patience
{
	ipc_reply(shift, 'wait');
}

# Talk to hfst-proc.
sub talk
{
	my ($trans, $what, $wait) = @_;
	my ($waited, @output);

	# hfst-proc throws up if it encounters unknown escape sequences,
	# so just ban them.  Also reject '^' and '$' except if they are
	# delimiters and $isgen.
	my $isgen = $$trans[3];
	my $nothat = qr/[^\^\$]/;
	return ("failed", "invalid input")
		if ($what =~ /\\/ || $what !~ ($isgen
			? qr/^(\^)?$nothat*(?(1)\$)$/o
			: qr/^$nothat*$/o));

	# Tell hfst-proc $what to do and wait for its reply terminated by
	# an empty line.
	local $\ = "";
	print { $$trans[0] } Encode::encode('utf8', "$what\n\n\n");
	my $expectempty = 1;
	for (;;)
	{
		# If the client expects longer reply time, wait up to 0.5s
		# and invoke $wait() if we indeed didn't receive anything.
		if (defined $wait && !$waited)
		{
			my $rfd = '';
			vec($rfd, fileno($$trans[1]), 1) = 1;

			my $ret = select($rfd, undef, undef, 0.5);
			if (!defined $ret)
			{
				kill('TERM', $$trans[2]);
				return ('fatal', @output);
			} elsif (!$ret)
			{
				&$wait();
				$waited = 1;
			}
		}

		# Either there's something to read or we can block now.
		my $line = readline($$trans[1]);
		if (!defined $line)
		{	# Connection lost with hfst-proc, possibly it's dead,
			# but kill it anyway since we can't use it anymore.
			kill('TERM', $$trans[2]);
			return ('fatal', @output);
		} elsif ($expectempty)
		{
			$expectempty = $line ne "\n";
		} elsif (!@output || $line ne "\n")
		{	# Buffer all output until we know for sure whether
			# we've succeeded.  If we failed @output may contain
			# the explanation.  The forced substitution is
			# necessary because the encoding modulesd of Perl
			# seem to consider it an invalid sequence and they
			# would prevent the translation of subseqeuent
			# characters of the string.
			chomp($line);
			$line =~ s/\xe2\x80\x90/-/g;
			push(@output, Encode::decode('utf8', $line));
		} else
		{
			return ('ok', @output);
		}
	}
}

# Start up an instance of hfst-proc using $transducer.
sub load
{
	my ($sender, $transducer) = @_;

	# Search for the $transducer in @path.
	my @path = qw(. /usr/local/lib/omorfi /usr/lib/omorfi);
	push(@path, $FindBin::RealBin);
	unshift(@path, "$ENV{'HOME'}/lib/omorfi")
		if defined $ENV{'HOME'};

	# Find the transducer in one of the directories of @path.
	# If we cannot, give hfst-proc the basename in the hope
	# that it will be able to locate it.
	my $fname = "$transducer.hfst.ol";
	if ($fname !~ m{/})
	{
		foreach my $dir (@path)
		{
			my $try = "$dir/$fname";
			next unless -f $try;
			$fname = $try;
			last;
		}
	}

	# Arguments to hfst-proc.
	my @args = ($fname);
	my $isgen = $fname =~ /^generation/;
	unshift(@args, '-g') if $isgen;

	# Start hfst-proc and wait for its greeting.
	my ($sin, $sex);
	my $pid = open3($sex, $sin, $sin, 'hfst-proc', @args);
	my $trans = [ $sex, $sin, $pid, $isgen ];
	my ($status, @error) = talk($trans, "\n", sub { patience($sender) });

	if ($status eq 'ok')
	{
		return $trans;
	} else
	{
		ipc_reply($sender, @error
			? join(' ', 'transducer:', @error)
			: "failed to load $transducer");
		return undef;
	}
}

sub server
{
	require FindBin;
	my %transducers;

	# Add our directory to $PATH to search for hfst-proc there too.
	if (defined $ENV{'PATH'})
	{
		$ENV{'PATH'} .= ":$FindBin::RealBin";
	} else
	{
		$ENV{'PATH'}  =   $FindBin::RealBin;
	}

	$SIG{'PIPE'} = 'IGNORE';
	$SIG{'CHLD'} = sub
	{
		# Remove hfst-proc:s from %transducers as they die.
		while ((my $pid = waitpid(-1, WNOHANG)) > 0)
		{
			keys(%transducers);
			while (my ($name, $trans) = each(%transducers))
			{
				if ($$trans[2] == $pid)
				{
					warn "$name: transducer died";
					delete $transducers{$name};
				}
			}
		}
	};

	print "server started";
	for (;;)
	{
		my ($sender, $msg) = ipc_get_msg();
		next if !defined $msg;

		my ($cmd, @args) = @$msg;
		if ($cmd eq 'echo')
		{
			ipc_ready($sender, "you said |$args[0]|");
		} elsif ($cmd eq 'stop')
		{	# Stop the hfst-proc:s we launched and exit.
			kill('TERM', map($$_[2], values(%transducers)));
			ipc_ready($sender);
			print "server exiting";
			return 0;
		} elsif ($cmd eq 'load')
		{	# Load a transducer.
			my $trans;

			if (!defined $args[0])
			{
				ipc_reply($sender, "server: too few arguments");
			} elsif ($transducers{$args[0]})
			{	# Requested transducer already loaded.
				ipc_ready($sender);
			} elsif (defined ($trans = load($sender, $args[0])))
			{	# If load() was unsuccessful it has already
				# reported the error to the $sender.
				$transducers{$args[0]} = $trans;
				ipc_ready($sender);
			}
		} elsif ($cmd eq 'unload')
		{
			my $trans;

			if (!defined $args[0])
			{
				ipc_reply($sender, "server: too few arguments");
			} elsif (defined ($trans = delete $transducers{$args[0]}))
			{
				kill('TERM', $$trans[2]);
			}
			ipc_ready($sender);
		} elsif ($cmd eq 'trans')
		{	# Translate something with the specified transducer.
			my ($from, $what) = @args;
			my $trans;

			if (!defined $from || !defined $what)
			{
				ipc_reply($sender, "server: too few arguments");
				next;
			}

			# load() the transducer if it hasn't been.
			if (!defined ($trans = $transducers{$from}))
			{
				defined ($trans = load($sender, $from))
					or next;
				$transducers{$from} = $trans;
			}

			# Input for generation-type transducers need to be
			# enclosed in ^$.
			my $isgen = $$trans[3];
			$what = "^$what\$" if $isgen;

			# Talk to the transducer.
			my ($status, @output) = talk($trans, $what);
			if ($status eq 'fatal')
			{	# talk() failed, transducer unusable.
				ipc_reply($sender, join(" ", @output));
				delete $transducers{$from};
				next;
			} elsif ($status ne 'ok')
			{	# User error.
				ipc_reply($sender, $status);
				next;
			}

			# @output is nothing if we gave nothing.
			if (@output == 1 && $output[0] =~ /^\s*$/)
			{
				ipc_ready($sender);
				next;
			}

			# Clean up the @output and see if anything remained.
			my @reply = $isgen
				? ($output[-1])
				: grep(s/^\^(.*)\$$/$1/, @output);
			if (!defined $reply[0])
			{
				ipc_reply($sender,
					join(' ', 'transducer:', @output));
				next;
			}

			# Split the reply into translations and see
			# if hfst-proc was able to find anything at all.
			@reply = split(m{/}, $reply[0]);
			if ($isgen)
			{
				# -lakkaa/lakkaa/Lakkaa/LAKKAA
				# #akarmi or *akarmi
				undef @reply if $reply[0] =~ /^#/;
			} else
			{	# The ^$ terminators have already been removed.
				# The first "translation" is always the copy
				# of our input.
				# lakkaat/lakata<V><Act><Ind><Prs><Sg2>
				# akarmi/*akarmi
				shift(@reply);
			}
			undef @reply if $reply[0] =~ /^\*/;

			@reply  ? ipc_ready($sender, @reply)
				: ipc_reply($sender, 'not found');
		} else
		{
			ipc_reply($sender, "server: unknown command");
		}
	}
}

### Client ###
sub exchange
{
	my ($reply, $waited);

	return () if !ipc_request(@_);

	local $\ = "";
	for (;;)
	{
		if (!defined ($reply = ipc_get_msg()))
		{
			return ();
		} elsif ($$reply[0] ne 'wait')
		{
			last;
		} elsif (!$waited)
		{
			local $| = 1;
			print "Wait...";
			$waited = 1;
		}
	}

	print "\n" if $waited;
	if ($$reply[0] eq 'ok')
	{
		shift(@$reply);
		return @$reply;
	} else
	{
		print join(' ', @$reply), "\n";
		return ();
	}
}

sub uniq
{
	my %hash;

	$hash{$_} = 1 foreach @_;
	return grep(delete $hash{$_}, @_);
}

# Main starts here
my $default;
my %transducers =
(
	'a' => 'morphology.apertium',
	'c' => 'morphology.colorterm',
	'g' => 'generation.apertium',
);

$\ = "\n";
ipc_init() or exit 1;

# Parse the command line.  Load the colorterm transducer by default.
@ARGV = qw(-c) if !@ARGV;
foreach my $arg (@ARGV)
{
	if ($arg =~ /^-([@{[join('', 'A', 'N', keys(%transducers))]}])$/o)
	{
		if ($1 eq 'A')
		{	# Load all tranducers.
			exchange('load', $_) for values(%transducers);
			$default = $transducers{'c'} unless defined $default;
		} elsif ($1 eq 'N')
		{	# Don't load any transducers just yet.
			$default = $transducers{'c'} unless defined $default;
		} else
		{	# Load the specified transducer.
			my $trans = $transducers{$1};
			exchange('load', $trans);
			$default = $trans unless defined $default;
		}
	} elsif ($arg =~ /^-([a-z]):(.+)$/)
	{	# Load the specified transducer and recognize it by $abrv.
		my ($abrv, $trans) = ($1, $2);
		exchange('load', $trans);
		$transducers{$abrv} = $trans;
		$default = $trans unless defined $default;
	} else
	{
		warn "unknown argument $arg";
	}
}

my $term = Term::ReadLine->new('omorfi');
while (defined ($_ = $term->readline('omorfi> ')))
{
	next if /^\s*$/;

	if (s/^!//)
	{	# Send a command to the server.
		my @cmd = split();
		if (!@cmd)
		{
			next;
		} elsif ($cmd[0] eq 'detach')
		{	# Quit without stopping the server.
			exit;
		} elsif ($cmd[0] eq 'start')
		{	# Restart the server.
			ipc_init('server');
		} else
		{
			exchange(@cmd);
		}
	} elsif (/^\[(.*)\]$/)
	{	# Translate from Finnish to English.
		system('transltr.pl', 'fi-en', Repul::repul($1));
	} else
	{
		my $trans = $default;
		my $addtohist = 0;

		# Which transducer to use?
		if (s/^(\w):\s+//)
		{
			if (!defined ($trans = $transducers{lc($1)}))
			{
				print "$1: unknown transducer";
				next;
			}
			$addtohist = $1 =~ /[A-Z]/;
		}

		my $what = Repul::repul($_);
		my @res  = exchange('trans', $trans, $what);
		if ($trans =~ /^generation/)
		{
			# Usually a lot of results are generated which
			# differ only in lettercase and in the presence
			# of dashes.
			$what = Encode::decode('latin1', $what);
			if ($what =~ /^-/)
			{	# Get rid of results without a frontal dash.
				@res = grep(/^-/, @res);
			} elsif ($what =~ /-$/)
			{	# Get rid of results without a closing dash.
				@res = grep(/-$/, @res);
			} else
			{	# Get rid of results with dashes.
				@res = grep(!/^-/ && !/-$/, @res);
			}
			@res = uniq(map(lc($_), @res));

			# Since we uniformly converted all elements of @res
			# to lowercase, consider now the lettercase of the
			# input and conver the results accordingly.
			if ($what =~ /^[[:upper:]]+</)
			{	# All uppercase.
				@res = map(uc($_), @res);
			} elsif ($what =~ /^[[:upper:]][^[:upper:]]+</)
			{	# First letter is uppercase.
				@res = map(ucfirst($_), @res);
			}
		}

		foreach (@res)
		{
			print ' ' x 8, $_;
			$term->addhistory(Encode::encode('latin1', "g: $_"))
				if $addtohist;
		}
	}
}
exchange('stop');

# End of omorfi.pl
