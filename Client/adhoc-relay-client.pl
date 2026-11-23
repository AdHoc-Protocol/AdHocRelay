#!/usr/bin/perl
# AdHoc Relay Client, on Linux and macOS: an ordinary program of this computer - a WebSocket client, ssh, Remote
# Desktop, a browser - reaches a server that waits at a relay, directly when the two can, through the relay when they cannot.
# The program can only dial an address: it dials this utility, on this computer, and the utility does the rest for it.
#
#   perl adhoc-relay-client.pl                                                asks, as a menu; the answers kept for the next start
#   perl adhoc-relay-client.pl --meet router.example.org:41933 --token K7QM2XHP9RTA4WZD --listen 41933
#
# --meet is the line the server shows for its client: the relay and the port of meeting. --token is the token of the server, 16
# letters and digits, the server gives it with the line. --listen is where the program of this computer connects: a port of
# 127.0.0.1, or address:port. --first is the first port of the relay, 40000 unless given: it answers STUN there. --wait is how
# long the two dial each other before the relay is taken, 2.5 s unless given.
#
# For each connection that comes, in a process of its own: it learns where it can be reached - the address and the port the
# relay sees, by STUN at its first port, none when its NAT changes the port; its LAN address; its IPv6 address -, and calls the
# server at the port of meeting: the key of a call - 8 bytes of SHA-256 of "adhoc-relay call" and the token - and those 30 bytes.
# The relay sends the call on to the server, and its 30 bytes back. Both dial each other from the local ports they called and
# knocked from: over IPv6 when both have it, in their LAN when both are behind one NAT, else at their public addresses - a new SYN
# each 300 ms, and at once after a refusal. The first connection made is kept; nothing within --wait, nothing to call with, the
# call refused or not answered: the relay, at the port of meeting, as any client. Either way the token goes first, then the
# bytes as they are, both ways. Without a token: through the relay, nothing written - as the program itself would dial the line.
# Only perl and its own modules: nothing to install.

use strict;
use warnings;
use utf8;
use IO::Socket::INET;
use IO::Select;
use Socket qw(PF_INET PF_INET6 AF_INET6 SOCK_STREAM SOCK_DGRAM IPPROTO_UDP IPPROTO_IPV6 IPV6_V6ONLY SOL_SOCKET SO_ERROR SO_REUSEADDR SO_KEEPALIVE IPPROTO_TCP TCP_NODELAY INADDR_ANY IN6ADDR_ANY inet_aton inet_ntoa inet_pton inet_ntop pack_sockaddr_in unpack_sockaddr_in pack_sockaddr_in6 unpack_sockaddr_in6);
use POSIX qw(EINVAL ENOSYS EINPROGRESS ECONNREFUSED WNOHANG);
use Config;
use Time::HiRes qw(time sleep);
use File::Basename qw(dirname);
use File::Spec;

# SHA-256 ( FIPS 180-4 ) in perl itself: a perl cut down to its interpreter - perl-base of Debian, perl-interpreter of Fedora - has
# no Digest::SHA. Sums by the remainder of 2^32, not by a mask: right on a perl of 32 bits too
sub own_sha256 {
    my ($m) = @_;
    my @k = map { hex } qw(428a2f98 71374491 b5c0fbcf e9b5dba5 3956c25b 59f111f1 923f82a4 ab1c5ed5 d807aa98 12835b01 243185be 550c7dc3
        72be5d74 80deb1fe 9bdc06a7 c19bf174 e49b69c1 efbe4786 0fc19dc6 240ca1cc 2de92c6f 4a7484aa 5cb0a9dc 76f988da 983e5152 a831c66d
        b00327c8 bf597fc7 c6e00bf3 d5a79147 06ca6351 14292967 27b70a85 2e1b2138 4d2c6dfc 53380d13 650a7354 766a0abb 81c2c92e 92722c85
        a2bfe8a1 a81a664b c24b8b70 c76c51a3 d192e819 d6990624 f40e3585 106aa070 19a4c116 1e376c08 2748774c 34b0bcb5 391c0cb3 4ed8aa4a
        5b9cca4f 682e6ff3 748f82ee 78a5636f 84c87814 8cc70208 90befffa a4506ceb bef9a3f7 c67178f2);
    my @h = map { hex } qw(6a09e667 bb67ae85 3c6ef372 a54ff53a 510e527f 9b05688c 1f83d9ab 5be0cd19);
    my ($all, $two32) = (0xffffffff, 4294967296);
    my $rot = sub { (($_[0] >> $_[1]) | ($_[0] << (32 - $_[1]))) & $all };
    my $bits = length($m) * 8;
    $m .= "\x80";
    $m .= "\0" x ((56 - length($m) % 64) % 64);
    $m .= pack('N2', 0, $bits);
    for (my $at = 0; $at < length $m; $at += 64) {
        my @w = unpack 'N16', substr($m, $at, 64);
        for my $i (16 .. 63) {
            my ($x, $y) = @w[$i - 15, $i - 2];
            $w[$i] = ($w[$i - 16] + ($rot->($x, 7) ^ $rot->($x, 18) ^ ($x >> 3)) + $w[$i - 7] + ($rot->($y, 17) ^ $rot->($y, 19) ^ ($y >> 10))) % $two32;
        }
        my @v = @h;
        for my $i (0 .. 63) {
            my $one = ($v[7] + ($rot->($v[4], 6) ^ $rot->($v[4], 11) ^ $rot->($v[4], 25)) + (($v[4] & $v[5]) ^ (~$v[4] & $all & $v[6])) + $k[$i] + $w[$i]) % $two32;
            my $two = (($rot->($v[0], 2) ^ $rot->($v[0], 13) ^ $rot->($v[0], 22)) + (($v[0] & $v[1]) ^ ($v[0] & $v[2]) ^ ($v[1] & $v[2]))) % $two32;
            @v = (($one + $two) % $two32, $v[0], $v[1], $v[2], ($v[3] + $one) % $two32, $v[4], $v[5], $v[6]);
        }
        $h[$_] = ($h[$_] + $v[$_]) % $two32 for 0 .. 7;
    }
    return pack 'N8', @h;
}

# the hash: Digest::SHA of perl when it is there, else the one above
my $DIGEST = eval { require Digest::SHA; 1 };
sub sha256 { $DIGEST ? Digest::SHA::sha256($_[0]) : own_sha256($_[0]) }

binmode STDOUT, ':encoding(UTF-8)';
$| = 1;

# ── the window: each kind of news with its sign and colour; plain in a log or a pipe ──

my $colour = -t STDOUT && !$ENV{NO_COLOR};
my %tone = (good => '1;32', news => '36', wait => '33', warn => '33', bad => '1;31', quiet => '90', key => '1;33', name => '1;37');
sub paint { my ($text, $t) = @_; $colour ? "\e[$tone{$t}m$text\e[0m" : $text }
sub say { my ($sign, $t, $text) = @_; print " $sign ", paint($text, $t), "\n" }

# ── what the menu keeps beside the script: key = value ──

my $kept_file = File::Spec->catfile(dirname(File::Spec->rel2abs($0)), 'adhoc-relay-client.settings');

sub load_kept {
    my %k;
    if (open my $f, '<:encoding(UTF-8)', $kept_file) {
        while (<$f>) { $k{$1} = $2 if /^\s*(\w+)\s*=\s*(\S.*?)\s*$/ }
        close $f;
    }
    return \%k;
}

sub save_kept {
    my ($k) = @_;
    open my $f, '>:encoding(UTF-8)', $kept_file or return say('💾', 'quiet', "Not kept for the next start: $!");
    print $f "# AdHoc Relay Client: what the menu offers on Enter\n";
    print $f "$_ = $k->{$_}\n" for grep { defined $k->{$_} } qw(meet token listen first);
    close $f;
    chmod 0600, $kept_file; # the token: for this user alone
}

sub line {
    my ($prompt) = @_;
    print ' ', paint($prompt, 'news'), ' ';
    my $l = <STDIN>;
    exit 0 unless defined $l;
    $l =~ s/^\s+|\s+$//g;
    return $l;
}

# A port: 1…65535, as a number is written - the digits of ASCII, no zeros in front.
sub port_ok { defined $_[0] && $_[0] =~ /^[1-9][0-9]{0,4}\z/ && $_[0] <= 65535 }

# The line of the server for its client: the relay - a name or an IPv4 address - and the port of meeting. [ host, port ]; undef
# - no such line
sub meet_of {
    my ($host, $port) = ($_[0] // '') =~ /^\s*([^\s:@=,!?>]+):(\d+)\s*\z/ or return undef;
    return port_ok($port) ? [$host, $port] : undef;
}

# Where the program of this computer connects: a port alone - of 127.0.0.1 -, or address:port. [ address, port ]; undef - neither
sub listen_of {
    my ($t) = @_;
    $t //= '';
    $t =~ s/^\s+|\s+$//g;
    return ['127.0.0.1', $t] if port_ok($t);
    return [$1, $2] if $t =~ /^([^\s:]+):(\d+)\z/ && port_ok($2);
    return undef;
}

# A token: 16 letters and digits, as a key of the relay.
sub token_ok { ($_[0] // '') =~ /^[A-Za-z0-9]{16}\z/ }

# ── the menu, when nothing was given ──

sub menu {
    my $k = load_kept();
    print "\n";
    my ($meet, $token, $listen, $first);
    while (1) {
        my $typed = line($k->{meet} ? "The line of the server - Enter for $k->{meet}:" : 'The line of the server, the relay and the port of meeting, such as router.example.org:41933:');
        $typed = $k->{meet} if $typed eq '' && $k->{meet};
        last if $meet = meet_of($typed);
        say('💡', 'warn', 'As the server shows it: a name or an address of the relay, :, the port of meeting');
    }
    while (1) {
        my $typed = line(token_ok($k->{token}) ? 'Its token - Enter for the one of last time, - for none:' : 'Its token, 16 letters and digits - Enter for none: through the relay:');
        $token = $typed eq '' ? (token_ok($k->{token}) ? $k->{token} : undef) : $typed eq '-' ? undef : $typed;
        last if !defined $token || token_ok($token);
        say('💡', 'warn', 'A token is 16 letters and digits, as the server shows it');
    }
    my $suggest = $k->{listen} // $meet->[1];
    while (1) {
        my $typed = line("The port the program of this computer connects to, of 127.0.0.1, or address:port - Enter for $suggest:");
        $typed = $suggest if $typed eq '';
        last if $listen = listen_of($typed);
        say('💡', 'warn', 'A port, such as 3390, or an address and a port, such as 0.0.0.0:3390');
    }
    # the first port matters to the direct way alone: STUN is asked there
    $first = $k->{first} // 40000;
    if (defined $token) {
        while (1) {
            my $typed = line("The first port of the relay, where it answers STUN - Enter for $first:");
            $typed = $first if $typed eq '';
            if (port_ok($typed)) { $first = $typed; last }
            say('💡', 'warn', 'A port: 1…65535, as its owner gave it - 40000 unless set otherwise');
        }
    }
    $k->{meet} = "$meet->[0]:$meet->[1]";
    $k->{token} = $token;
    $k->{listen} = "$listen->[0]:$listen->[1]" eq "127.0.0.1:$listen->[1]" ? $listen->[1] : "$listen->[0]:$listen->[1]";
    $k->{first} = $first;
    save_kept($k);
    print "\n";
    return ($meet, $token, $listen, $first);
}

# ── the arguments, or the menu ──

my ($MEET, $TOKEN, $LISTEN, $FIRST, $WAIT);
while (my $a = shift @ARGV) {
    if ($a eq '--meet') { $MEET = meet_of(shift @ARGV) or die "--meet <relay>:<port of meeting>, such as router.example.org:41933\n" }
    elsif ($a eq '--token') { $TOKEN = shift(@ARGV) // ''; die "--token <16 letters and digits>, such as K7QM2XHP9RTA4WZD\n" unless token_ok($TOKEN) }
    elsif ($a eq '--listen') { $LISTEN = listen_of(shift @ARGV) or die "--listen <port> or <address:port>, such as 41933 or 0.0.0.0:41933\n" }
    elsif ($a eq '--first') { $FIRST = shift(@ARGV); die "--first <the first port of the relay>, such as 40000\n" unless port_ok($FIRST) }
    elsif ($a eq '--wait') { $WAIT = shift(@ARGV) // ''; die "--wait <seconds>, such as 2.5\n" unless $WAIT =~ /^\d+(\.\d+)?\z/ && $WAIT > 0 && $WAIT <= 60 }
    else {
        print "perl adhoc-relay-client.pl [--meet <relay>:<port of meeting> --listen <port> | <address:port> [--token <token>]\n",
            "    [--first <first port of the relay>] [--wait <seconds>]]\n",
            "  the line of the server for its client, its token, and where the program of this computer connects;\n",
            "  the first port 40000 and the wait 2.5 s unless given. Without a token: through the relay\n",
            "  with no arguments it asks, and keeps the answers beside it\n";
        exit 2;
    }
}

print "\n ", paint('AdHoc Relay Client', 'name'), "\n ",
    paint('a program of this computer reaches a server at a relay: directly when the two can, else through the relay', 'quiet'), "\n";
if (!defined $MEET || !defined $LISTEN) {
    die "--meet and --listen go together\n" if defined $MEET || defined $LISTEN;
    die "--token, --first and --wait go with --meet and --listen\n" if defined $TOKEN || defined $FIRST || defined $WAIT;
    die "no terminal to ask in: give --meet and --listen\n" unless -t STDIN;
    ($MEET, $TOKEN, $LISTEN, $FIRST) = menu();
}
$FIRST //= 40000;
$WAIT //= 2.5;
my ($HOST, $PORT) = @$MEET;
utf8::downgrade($TOKEN) if defined $TOKEN;
# the key of a call of the token: what a call begins with, and what the knocks of the server carry - the first 8 bytes of SHA-256
# of "adhoc-relay call" and the token. The token itself goes only to the server, the first bytes of each connection
my $CALL = defined $TOKEN ? substr(sha256("adhoc-relay call$TOKEN"), 0, 8) : undef;

my $listener = IO::Socket::INET->new(LocalAddr => $LISTEN->[0], LocalPort => $LISTEN->[1], Proto => 'tcp', Listen => 64, ReuseAddr => 1)
    or die "Cannot listen at $LISTEN->[0]:$LISTEN->[1]: $!\n";
my $here = "$LISTEN->[0]:$LISTEN->[1]";

say('🔌', 'good', "Listening at $here: a program of this computer connects there, and reaches the server at $HOST:$PORT");
if (defined $TOKEN) { say('🎫', 'news', "With the token: directly when the two can, else through the relay; STUN at $HOST:$FIRST, $WAIT s to meet directly") }
else { say('🎫', 'warn', 'No token: each connection goes through the relay, as the program itself would dial the line') }
say('👀', 'wait', 'Waiting for the program of this computer…');

# ── the direct way ──

# 8 random bytes of the system: what goes with each STUN request - nothing perl makes up, which can be guessed
sub random8 {
    my $b = '';
    if (open my $r, '<:raw', '/dev/urandom') { read $r, $b, 8; close $r }
    die "No random bytes from /dev/urandom\n" if length $b != 8;
    return $b;
}

# SO_REUSEADDR on a TCP socket of the local port, and SO_REUSEPORT too where the system has it: the dialings of the server go from
# the one local port at once, and macOS lets two sockets bind one port only so
sub reuse {
    my ($s) = @_;
    setsockopt($s, SOL_SOCKET, SO_REUSEADDR, 1);
    eval { setsockopt($s, SOL_SOCKET, Socket::SO_REUSEPORT(), 1) };
    return 1;
}

# The address and the port the relay sees a UDP socket at, by STUN at its first port: a Binding Request of RFC 8489, the
# answer its XOR-MAPPED-ADDRESS, 32 bytes. Up to 3 requests, a second each. undef - no answer
sub stun {
    my ($u, $ip) = @_;
    my $to = pack_sockaddr_in($FIRST, $ip);
    my $tx = random8() . substr(random8(), 0, 4);
    for (1 .. 3) {
        send($u, "\x00\x01\x00\x00\x21\x12\xa4\x42$tx", 0, $to);
        my $end = time + 1;
        while ((my $left = $end - time) > 0) {
            IO::Select->new($u)->can_read($left) or last;
            my $back = recv($u, my $got, 64, 0);
            next unless defined $back && $back eq $to && length $got == 32 && substr($got, 8, 12) eq $tx && substr($got, 20, 6) eq "\x00\x20\x00\x08\x00\x01";
            return [ inet_ntoa(substr($got, 28, 4) ^ "\x21\x12\xa4\x42"), unpack('n', substr($got, 26, 2)) ^ 0x2112 ];
        }
    }
    return undef;
}

# The address of this computer the way to the relay goes from; undef - none
sub lan_of {
    my $s = IO::Socket::INET->new(PeerAddr => inet_ntoa($_[0]), PeerPort => $FIRST, Proto => 'udp') or return undef;
    return $s->sockhost;
}

# The IPv6 address of this computer the way out goes from; undef - none, or of the link only
sub v6_of {
    socket(my $s, PF_INET6, SOCK_DGRAM, IPPROTO_UDP) or return undef;
    connect($s, pack_sockaddr_in6(9, inet_pton(AF_INET6, '2001:db8::1'))) or return undef;
    my $text = inet_ntop(AF_INET6, (unpack_sockaddr_in6(getsockname($s)))[1]);
    return $text =~ /^fe80/i ? undef : $text;
}

# Where one can be reached, as the 30 bytes of a call and its answer - the public IPv4 and port, the LAN IPv4 and port, the IPv6
# and port, zeros for none -, and back
sub encode {
    my ($w) = @_;
    return ($w->{pub} ? inet_aton($w->{pub}[0]) . pack('n', $w->{pub}[1]) : "\0" x 6)
        . ($w->{lan} ? inet_aton($w->{lan}[0]) . pack('n', $w->{lan}[1]) : "\0" x 6)
        . ($w->{v6} ? inet_pton(AF_INET6, $w->{v6}[0]) . pack('n', $w->{v6}[1]) : "\0" x 18);
}
sub decode {
    my ($b) = @_;
    my %w;
    $w{pub} = [ inet_ntoa(substr($b, 0, 4)), unpack('n', substr($b, 4, 2)) ] if substr($b, 0, 4) ne "\0" x 4;
    $w{lan} = [ inet_ntoa(substr($b, 6, 4)), unpack('n', substr($b, 10, 2)) ] if substr($b, 6, 4) ne "\0" x 4;
    $w{v6} = [ inet_ntop(AF_INET6, substr($b, 12, 16)), unpack('n', substr($b, 28, 2)) ] if substr($b, 12, 16) ne "\0" x 16;
    return \%w;
}

# Where to dial the other: IPv6 when both have it; behind one NAT - one public address - its LAN address, else its public one
sub targets {
    my ($mine, $other) = @_;
    my @t;
    push @t, { how => 'over IPv6', to => $other->{v6} } if $mine->{v6} && $other->{v6};
    if ($mine->{pub} && $other->{pub}) {
        if ($mine->{pub}[0] eq $other->{pub}[0]) { push @t, { how => 'in the LAN', to => $other->{lan} } if $other->{lan} }
        else { push @t, { how => 'at its public address', to => $other->{pub} } }
    }
    return @t;
}

# The targets as words: 203.0.113.5:51000 at its public address, [2001:db8::5]:51000 over IPv6
sub ways { join ', ', map { ($_->{to}[0] =~ /:/ ? "[$_->{to}[0]]" : $_->{to}[0]) . ":$_->{to}[1] $_->{how}" } @_ }

# A local port to call and dial from: free for UDP and for TCP. [ its UDP socket, the port ]; undef - none now
sub local_port {
    for (1 .. 20) {
        # bound by hand: IO::Socket::INET binds no port 0
        my $u = IO::Socket::INET->new;
        socket($u, PF_INET, SOCK_DGRAM, IPPROTO_UDP) && bind($u, pack_sockaddr_in(0, INADDR_ANY)) or next;
        my $p = (unpack_sockaddr_in(getsockname($u)))[0];
        socket(my $t, PF_INET, SOCK_STREAM, IPPROTO_TCP) or next;
        reuse($t);
        my $free = bind($t, pack_sockaddr_in($p, INADDR_ANY));
        close $t;
        return [$u, $p] if $free;
    }
    return undef;
}

# A TCP socket from the local port, dialing there, not waiting. undef - it could not
sub dial {
    my ($local, $host, $port) = @_;
    my $six = $host =~ /:/;
    my $s = IO::Socket::INET->new;
    socket($s, $six ? PF_INET6 : PF_INET, SOCK_STREAM, IPPROTO_TCP) or return undef;
    reuse($s);
    setsockopt($s, IPPROTO_IPV6, IPV6_V6ONLY, 1) if $six;
    bind($s, $six ? pack_sockaddr_in6($local, IN6ADDR_ANY) : pack_sockaddr_in($local, INADDR_ANY)) or return undef;
    $s->blocking(0);
    connect($s, $six ? pack_sockaddr_in6($port, inet_pton(AF_INET6, $host)) : pack_sockaddr_in($port, inet_aton($host)))
        or $! == EINPROGRESS or return undef;
    return $s;
}

# The state of a dialing socket: 2 - SYN sent, nothing came back yet. TCP_INFO of Linux, TCP_CONNECTION_INFO of macOS, the first
# byte of both; elsewhere, as SYN sent
sub sent {
    my ($s) = @_;
    my $opt = $^O eq 'linux' ? 11 : $^O eq 'darwin' ? 0x106 : return 1;
    my $info = getsockopt($s, IPPROTO_TCP, $opt) // return 1;
    return unpack('C', $info) == 2;
}

# The server met directly: [ the connection, how ] - or [ undef, why not ]. The local port learns where it can be reached, and
# calls: the key of a call and those 30 bytes to the port of meeting, a second for the answer, 6 s in all. Refused - the server
# does not dial the relay this moment -: again a second later, from a new local port: the call before is bound to the local port
# of the server of that moment, and each call from the same port would go there. The answer - where the server can be reached -
# is dialed from the local port, each target a new SYN each 300 ms while nothing came back, and at once after a refusal, up to
# WAIT seconds; the first connection made is kept
sub direct {
    my ($ip) = @_;
    my ($udp, $local, $me);
    my $fresh = sub {
        close $udp if $udp;
        my $l = local_port() or return 0;
        ($udp, $local) = @$l;
        $me = here($udp, $ip, $local);
        return $me->{pub} || $me->{v6};
    };
    $fresh->() or return [undef, $udp ? 'nothing to call with: the NAT of this computer changes the port, and no IPv6' : "no free local port: $!"];
    my ($answer, $why) = (undef, 'the call got no answer: another token, or the server waits without one');
    my $calling = time + 6;
    while (time < $calling) {
        connect($udp, pack_sockaddr_in($PORT, $ip));
        send($udp, $CALL . encode($me), 0);
        IO::Select->new($udp)->can_read(1) or next;
        my $back = recv($udp, my $got, 64, 0);
        if (!defined $back) {
            # no way to the relay now: again in a second, not a storm of calls
            if ($! != ECONNREFUSED) { sleep 1; next }
            $why = 'the call was refused: the server does not dial the relay this moment';
            sleep 1;
            $fresh->() or return [undef, 'nothing to call with: the NAT of this computer changes the port, and no IPv6'];
            next;
        }
        if (length $got == 30) { $answer = decode($got); last }
    }
    close $udp;
    return [undef, $why] unless $answer;
    my @targets = map { +{ %$_ } } targets($me, $answer);
    return [undef, 'nowhere to dial: no IPv6 on both, and a NAT of the two changes the port'] unless @targets;
    my ($met, $how);
    my $until = time + $WAIT;
    while (!$met && time < $until) {
        for my $t (grep { !$_->{done} } @targets) {
            if ($t->{sock} && time - $t->{at} >= 0.3 && sent($t->{sock})) { close $t->{sock}; $t->{sock} = undef }
            next if $t->{sock};
            $t->{sock} = dial($local, @{ $t->{to} }) or next;
            $t->{at} = time;
        }
        my $w = IO::Select->new(map { $_->{sock} } grep { $_->{sock} } @targets);
        my (undef, $writable) = IO::Select->select(undef, $w->count ? $w : undef, undef, 0.05);
        for my $s (@{ $writable // [] }) {
            my ($t) = grep { $_->{sock} && $_->{sock} == $s } @targets or next;
            $t->{sock} = undef;
            # refused, or no way there: dialed again at the next look, while the time lasts
            if (unpack('i', getsockopt($s, SOL_SOCKET, SO_ERROR) // pack('i', 0))) { close $s; next }
            $t->{done} = 1;
            ($met, $how) = ($s, $t);
            last;
        }
    }
    close $_->{sock} for grep { $_->{sock} } @targets;
    return [undef, "the server dialed, ${\ ways(@targets)}; nothing connected within $WAIT s"] unless $met;
    $met->blocking(1);
    return [$met, 'directly, ' . ways($how)];
}

# Where this computer can be reached from the local port of the UDP socket `u`: the public address and port, when its NAT keeps
# the local port - else none -, the LAN address, the IPv6 address
sub here {
    my ($u, $ip, $local) = @_;
    my $pub = stun($u, $ip);
    my $lan = lan_of($ip);
    my $v6 = v6_of();
    return { pub => ($pub && $pub->[1] == $local ? $pub : undef), lan => ($lan ? [ $lan, $local ] : undef), v6 => ($v6 ? [ $v6, $local ] : undef) };
}

# ── passing the bytes ──

# splice(2) of Linux: the bytes go from one socket into a pipe and from the pipe into the other socket inside the kernel - they
# never enter this process, nothing copies them here. Its number of the system call is of the processor and the ABI perl was
# built for, as the kernel has it: unknown - another processor, or macOS, which has no splice - none, and the bytes go through
# one buffer. A wrong number would call another system call: only those known are used
my $SPLICE = do {
    my ($arch, $wide) = ($Config{archname} // '', ($Config{ptrsize} // 4) == 8);
    $^O ne 'linux' ? undef
        : $arch =~ /^x86_64/ ? ($wide ? 275 : undef)
        : $arch =~ /^i[3-6]86/ ? 313
        : $arch =~ /^(aarch64|arm64)/ ? 76
        : $arch =~ /^arm/ ? 340
        : $arch =~ /^mips64/ ? ($wide ? 5263 : 6267)
        : $arch =~ /^mips/ ? 4304
        : $arch =~ /^riscv64/ ? 76
        : $arch =~ /^(powerpc|ppc)/ ? 283
        : $arch =~ /^s390x/ ? 306
        : undef;
};

# One way by splice: socket, pipe, socket, till `from` ends. The pipe made 1 MB where the system lets it ( F_SETPIPE_SZ ), 64 KB
# else: fewer calls for the same bytes. SPLICE_F_MOVE only - not SPLICE_F_MORE, which holds back a short last piece: a key
# pressed in ssh would wait for it. undef - splice cannot here, nothing moved: the buffer then
sub by_splice {
    my ($from, $to) = @_;
    defined $SPLICE && pipe(my $r, my $w) or return undef;
    fcntl($w, 1031, 1 << 20);
    my $size = fcntl($w, 1032, 0) || 65536;
    my ($in, $out, $pr, $pw) = map { fileno $_ } $from, $to, $r, $w;
    my $moved = 0;
    while (1) {
        my $n = syscall($SPLICE, $in, 0, $pw, 0, $size, 1);
        return $moved || ($! != EINVAL && $! != ENOSYS) ? 1 : undef if $n < 0;
        return 1 if $n == 0;
        $moved = 1;
        while ($n > 0) {
            my $m = syscall($SPLICE, $pr, 0, $out, 0, $n, 1);
            return 1 if $m <= 0;
            $n -= $m;
        }
    }
}

# One way through one buffer, allocated once: sysread fills it in place, syswrite sends that very buffer from an offset till all
# of it is gone - no piece of the bytes copied into another string, nothing allocated per read
sub by_copy {
    my ($from, $to) = @_;
    my $size = 262144;
    my $buf = "\0" x $size;
    while (my $n = sysread($from, $buf, $size)) {
        for (my $off = 0; $off < $n;) {
            my $w = syswrite($to, $buf, $n - $off, $off) // return;
            $off += $w;
        }
    }
}

# Both ways at once, each in a process of its own - a blocking way each, so one that waits for its other end to take the bytes
# holds nothing of the other. A way that ends ends the sending of its other end only: a program that sends, ends its sending and
# waits for the answer gets it. The buffers of the sockets are left to the system: Linux, macOS and Windows grow them as the
# connection needs - to megabytes on a far one -, and a size set by a program turns that off, on Linux below the limit the system
# sets programs ( net.core.rmem_max, 208 KB by default )
sub pass_both {
    my ($a, $b) = @_;
    my $pid = fork;
    return say('❌', 'bad', "fork: $!") unless defined $pid;
    my ($from, $to) = $pid ? ($b, $a) : ($a, $b);
    by_splice($from, $to) // by_copy($from, $to);
    shutdown($to, 1);
    exit 0 unless $pid;
    waitpid($pid, 0);
}

# ── each connection ──

# A connection of the program of this computer: the server met, the token written first, and the bytes passed both ways till
# both sides end, each end told the other
sub serve {
    my ($came) = @_;
    my $who = $came->peerhost . ':' . $came->peerport;
    my $ip = inet_aton($HOST) or return say('❌', 'bad', "$who: the relay $HOST, no such address now");
    my ($met, $way) = defined $CALL ? @{ direct($ip) } : (undef, undef);
    unless ($met) {
        $met = IO::Socket::INET->new(PeerAddr => inet_ntoa($ip), PeerPort => $PORT, Proto => 'tcp', Timeout => 10)
            or return say('❌', 'bad', "$who: the relay, $HOST:$PORT, let nobody in: $!" . ($way ? " - $way" : ''));
        $way = 'through the relay' . ($way ? " - $way" : '');
    }
    say('✅', 'good', "$who met the server $way");
    setsockopt($_, IPPROTO_TCP, TCP_NODELAY, 1) for $came, $met;
    # Keepalive on the connection to the server: after 60 s of silence, a probe each 10 s, 6 of them. A server that is gone without
    # a word is found; and a session that is silent stays known to the NATs on the way, which forget a silent connection in minutes
    setsockopt($met, SOL_SOCKET, SO_KEEPALIVE, 1);
    if ($^O eq 'linux') { setsockopt($met, IPPROTO_TCP, $_->[0], $_->[1]) for [4, 60], [5, 10], [6, 6] } # TCP_KEEPIDLE, _KEEPINTVL, _KEEPCNT
    elsif ($^O eq 'darwin') { setsockopt($met, IPPROTO_TCP, 0x10, 60) } # TCP_KEEPALIVE, seconds of silence
    if (defined $TOKEN) {
        for (my $off = 0; $off < 16;) {
            my $w = syswrite($met, $TOKEN, 16 - $off, $off);
            return say('❌', 'bad', "$who: the server ended at once: $!") unless defined $w;
            $off += $w;
        }
    }
    pass_both($came, $met);
    say('👋', 'quiet', "$who ended");
}

# Each connection lives in a process of its own, gone with it: those that ended are taken off as the loop goes round, and counted
# - as many at once as MAX, no more
my ($MAX, $live) = (64, 0);
# a write to a connection that is gone is an error of that write, not the end of the process
$SIG{PIPE} = 'IGNORE';
my $waiting = IO::Select->new($listener);
while (1) {
    $live-- while $live > 0 && waitpid(-1, WNOHANG) > 0;
    $waiting->can_read(1) or next;
    my $came = $listener->accept or next;
    if ($live >= $MAX) { say('⚠️', 'warn', "$MAX connections at once already: one more turned away"); close $came; next }
    my $pid = fork;
    if (!defined $pid) { say('❌', 'bad', "fork: $!"); close $came; next }
    if ($pid == 0) { close $listener; serve($came); exit 0 }
    $live++;
    close $came;
}
