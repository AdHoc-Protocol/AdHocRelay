#!/usr/bin/perl
# AdHoc Relay, the server, on Linux and macOS: a service of this computer - Remote Desktop, SSH, VNC, a web server -, or of its
# network, reached by the client through a relay, with nothing to forward on the routers. The client uses its own program
# of that service, as with any address: Remote Desktop Connection, ssh, a VNC viewer, a browser. Nothing is installed there.
#
#   perl adhoc-relay-server.pl                                              asks, as a menu; the answers kept for the next start
#   perl adhoc-relay-server.pl --meet 'Tr7kQ2xZp4Lm9sWd👉router.example.org:40000👉' --forward 22
#   perl adhoc-relay-server.pl --meet 'Tr7kQ2xZp4Lm9sWd👉router.example.org:40000👉' --forward 22 --token K7QM2XHP9RTA4WZD
#
# The line is a key, 👉, the relay and its first port, 👉 - of the password, of a fixed port, of a user: all alike. No key travels:
# the script binds a port of meeting at the relay - the id of its key, its own id, 8 random bytes of this start, and 8 bytes of
# HMAC-SHA256 the key makes of them and of the address the relay sees it at -, prints the line for the client, the relay and that
# port, and from then on knocks at the port - with the key of its knocks, 16 bytes of HMAC of the port and that address - and
# dials it, a try after another, from one local port; how often it knocks, how long a try is and how often it binds anew the
# relay says in its answer - 20 s, 31 s and 30 minutes unless set otherwise there. Each connection that meets is joined to the
# server, in a process of its own: the bytes go as they are, both ways. The next one is awaited at once. It binds anew, and at
# once when the relay refuses its knock: this computer is behind another address then. A relay whose address changes has its
# address kept by others: the line names them, each with a key of reading, then the first port of the relay -
# Fx2pL8wNq7Rk3mZa🌐Rk8mP2qLx3Vb7NtY👉203.0.113.7:40000🌐Hx4nT7wAc5Jd2QeL👉198.51.100.9:40000🌐40000👉 -, and the address is read
# there, again every 30 s; an answer the key of reading did not sign is not taken. The signs may be typed as > and @. Only perl
# and its own modules: nothing to install.
#
# With a token, 16 letters and digits, the client is AdHoc Relay Client, and the two meet directly when they can:
# the knocks carry the key of a call of the token, 8 bytes of SHA-256 of "adhoc-relay call" and the token; a call the relay sends
# on is answered with where this server can be reached - by STUN at the first port of the relay, in its LAN, over IPv6 -, and
# the client is dialed there from the local port of the knocks, a new SYN each 300 ms, 3 s. Each connection, through the relay
# or directly, begins with the token: one without it is cut off, the program of the client that dials the line itself too.

use strict;
use warnings;
use utf8;
use IO::Socket::INET;
use IO::Select;
use Socket qw(PF_INET PF_INET6 AF_INET6 SOCK_STREAM SOCK_DGRAM IPPROTO_UDP IPPROTO_IPV6 IPV6_V6ONLY SOL_SOCKET SO_ERROR SO_REUSEADDR SO_KEEPALIVE IPPROTO_TCP TCP_NODELAY INADDR_ANY IN6ADDR_ANY inet_aton inet_ntoa inet_pton inet_ntop pack_sockaddr_in unpack_sockaddr_in pack_sockaddr_in6 unpack_sockaddr_in6);
use POSIX qw(EINVAL ENOSYS EINPROGRESS ECONNREFUSED ECONNRESET EADDRINUSE EADDRNOTAVAIL WNOHANG);
use Config;
use Time::HiRes ();
use File::Basename qw(dirname);
use File::Spec;

# SHA-256 ( FIPS 180-4 ) and HMAC ( RFC 2104 ) in perl itself: a perl cut down to its interpreter - perl-base of Debian,
# perl-interpreter of Fedora - has no Digest::SHA. Sums by the remainder of 2^32, not by a mask: right on a perl of 32 bits too
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
sub own_hmac_sha256 {
    my ($words, $key) = @_;
    $key = own_sha256($key) if length $key > 64;
    $key .= "\0" x (64 - length $key);
    return own_sha256(($key ^ ("\x5c" x 64)) . own_sha256(($key ^ ("\x36" x 64)) . $words));
}

# the hash of the keys: Digest::SHA of perl when it is there, else the one below
my $DIGEST = eval { require Digest::SHA; 1 };
sub sha256 { $DIGEST ? Digest::SHA::sha256($_[0]) : own_sha256($_[0]) }
sub hmac_sha256 { $DIGEST ? Digest::SHA::hmac_sha256($_[0], $_[1]) : own_hmac_sha256($_[0], $_[1]) }


binmode STDOUT, ':encoding(UTF-8)';
$| = 1;

# ── the window: each kind of news with its sign and colour; plain in a log or a pipe ──

my $colour = -t STDOUT && !$ENV{NO_COLOR};
my %tone = (good => '1;32', news => '36', wait => '33', warn => '33', bad => '1;31', quiet => '90', key => '1;33', name => '1;37');
sub paint { my ($text, $t) = @_; $colour ? "\e[$tone{$t}m$text\e[0m" : $text }
sub say { my ($sign, $t, $text) = @_; print " $sign ", paint($text, $t), "\n" }

# ── what to open: the servers people reach most, and any port ──

my $RDP = 3389;
my @SERVICES = (
    ['🪟', 'Remote Desktop of Windows', '3389', 'Remote Desktop Connection ( mstsc ); xrdp on Linux: a long, strong password on the account is a must'],
    ['🔐', 'SSH', '22', 'ssh -p <port> <relay>'],
    ['🖼️', 'VNC', '5900', 'a VNC viewer'],
    ['🌐', 'A web server', '80', 'a browser: http://<relay>:<port>'],
    ['✏️', 'Another port', '', 'of this computer, or address:port of its network: you type which'],
);

# ── what the menu keeps beside the script: key = value ──

my $kept_file = File::Spec->catfile(dirname(File::Spec->rel2abs($0)), 'adhoc-relay-server.settings');

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
    print $f "# AdHoc Relay, the server: what the menu offers on Enter\n";
    print $f "$_ = $k->{$_}\n" for grep { defined $k->{$_} } qw(service forward meet password token);
    close $f;
    chmod 0600, $kept_file; # the password of the relay: for this user alone
}

# ── the keys and lines typed ──

# The key pressed, alone, no Enter after it: the terminal in raw mode for it. Without a terminal, the next character.
sub key {
    my $c;
    if (-t STDIN) {
        require POSIX;
        my $t = POSIX::Termios->new;
        $t->getattr(0);
        my $was = $t->getlflag;
        $t->setlflag($was & ~(POSIX::ECHO() | POSIX::ICANON()));
        $t->setcc(POSIX::VMIN(), 1);
        $t->setattr(0, POSIX::TCSANOW());
        sysread STDIN, $c, 1;
        $t->setlflag($was);
        $t->setattr(0, POSIX::TCSANOW());
    } else {
        sysread STDIN, $c, 1 or exit 0;
    }
    exit 0 unless defined $c;
    return $c eq "\r" ? "\n" : $c;
}

sub line {
    my ($prompt) = @_;
    print ' ', paint($prompt, 'news'), ' ';
    my $l = <STDIN>;
    exit 0 unless defined $l;
    $l =~ s/^\s+|\s+$//g;
    return $l;
}

# Where the connections go, of what was typed: a port alone - of this computer -, or address:port. undef - neither.
sub target {
    my ($t) = @_;
    $t =~ s/^\s+|\s+$//g;
    return "127.0.0.1:$t" if $t =~ /^\d+$/ && $t > 0 && $t < 65536;
    return $t if $t =~ /^([^\s:]+):(\d+)$/ && $2 > 0 && $2 < 65536;
    return undef;
}

# A line with the signs of the keyboard: 👉 >, 🌐 @, 👀 ?, ✏️ ! - what makes an emoji coloured, or the colour of skin, left out. Typed
# or given as an argument, it comes as bytes of UTF-8.
sub plain {
    my ($t) = @_;
    utf8::decode($t) unless utf8::is_utf8($t);
    $t =~ s/[\x{FE0F}\x{1F3FB}-\x{1F3FF}]//g;
    $t =~ tr/\x{1F449}\x{1F310}\x{1F440}\x{270F}/>@?!/;
    $t =~ s/^\s+|\s+$//g;
    return $t;
}

# The line as people see it: the signs of the keyboard as emoji.
sub pretty { (my $t = $_[0] // '') =~ tr/>@?/\x{1F449}\x{1F310}\x{1F440}/; $t =~ s/!/\x{270F}\x{FE0F}/g; return $t }

# A port: 1…65535, as a number is written - the digits of ASCII, no zeros in front: one form for every program that takes lines.
sub port_ok { defined $_[0] && $_[0] =~ /^[1-9][0-9]{0,4}\z/ && $_[0] <= 65535 }

# The relay as its owner gave it - the page of AdHoc Relay copies it so -, one of
#   <key>👉<point>[:<its first port>]👉                                    the key, and where it binds a port: the relay
#   <key>🌐<read>👉<keeper>:<its port>[🌐<read>👉<keeper>:<its port>...]🌐<its first port>👉
#                                                                        a relay whose address changes: read from its keepers, in turn
# or the relay alone, <point>[:<its first port>], its key asked then. The key: the password, the key of a fixed port, of a user -
# the relay answers the port of each. The 👉 at the end may be left out. As { key, port, host } or { key, port, reads => [ [ key
# of reading, keeper, its first port ], ... ] }: key undef when the line has none. undef - no such line.
sub point {
    my $t = plain($_[0]);
    my %p;
    my $rest = $t;
    my $read;
    if ($t =~ /[>@]/) {
        $t =~ s/>\z//;
        ($p{key}, $read, $rest) = $t =~ /^([^>@]*)([>@])(.*)\z/ or return;
        $p{key} = undef if $p{key} eq '';
    }
    # 🌐 between the parts: where to read the address, each a read key 👉 a keeper and its port; after the last 🌐 the port
    if (($read // '') eq '@') {
        my @parts = split /@/, $rest, -1;
        my $port = pop @parts;
        return unless @parts && port_ok($port);
        for (@parts) {
            my ($key, $keeper, $asks) = /^\s*([A-Za-z0-9]{16})>([^\s:@=,!?>]+):(\d+)\s*\z/ or return;
            return unless port_ok($asks);
            push @{$p{reads}}, [$key, $keeper, $asks];
        }
        $p{port} = $port;
        return \%p;
    }
    my ($host, $port) = $rest =~ /^([^\s:@=,!?>]+)(?::(\d+))?\z/ or return;
    return if defined $port && !port_ok($port);
    @p{qw(host port)} = ($host, $port // 40000);
    return \%p;
}

# The line without its key, as the menu keeps it, the signs of the keyboard: > first, or @ before each read and the port; > last.
sub rest_of {
    my ($p) = @_;
    my $where = $p->{reads} ? join('', map { "\@$_->[0]>$_->[1]:$_->[2]" } @{$p->{reads}}) . "\@$p->{port}" : ">$p->{host}:$p->{port}";
    return $where . '>';
}

# The keys of reading hidden, for the screen.
sub hidden { (my $t = pretty($_[0])) =~ s/\x{1F310}[A-Za-z0-9]{16}/\x{1F310}****************/g; return $t }

# A password or a key: 16 letters and digits. A token is the same.
sub key_ok { ($_[0] // '') =~ /^[A-Za-z0-9]{16}\z/ }

# A new token: 16 letters and digits of the random bytes of the system, those mistaken for one another left out - as the relay
# makes its keys. Each character alike: a byte past the last whole run of the letters is left out, not folded onto the first
sub new_token {
    my $abc = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
    my $whole = 256 - 256 % length $abc;
    my $t = '';
    $t .= join '', map { substr($abc, ord($_) % length $abc, 1) } grep { ord($_) < $whole } split //, random8() while length $t < 16;
    return substr($t, 0, 16);
}

# What a whole line is, as docs/lines.tsv writes it - the line whole, the signs of the keyboard, the ports put in where the line
# has none -, or `error`: what every program takes alike.
sub parsed {
    my $p = point($_[0]);
    return 'error' unless $p && key_ok($p->{key});
    return $p->{key} . rest_of($p);
}

my $LINES = 'such as Tr7kQ2xZp4Lm9sWd👉router.example.org:40000👉, or Tr7kQ2xZp4Lm9sWd🌐Rk8mP2qLx3Vb7NtY👉203.0.113.7:40000🌐40000👉 - its address read there';

# ── the menu, when nothing was given ──

sub menu {
    my $k = load_kept();
    print "\n";
    say('🔌', 'news', 'What should the client reach through the relay?');
    print "\n";
    for my $i (0 .. $#SERVICES) {
        my ($sign, $name, $port, $about) = @{$SERVICES[$i]};
        my $what = $port ne '' ? "port $port · $about" : ($k->{forward} && ($k->{service} // 0) == $i + 1 ? "last time $k->{forward}" : $about);
        printf "    %s  %s  %s%s\n", paint($i + 1, 'key'), $sign, paint(sprintf('%-27s', $name), 'name'), paint($what, 'quiet');
    }
    print "\n ", paint($k->{service} ? "Press 1-5 · Enter: $k->{service} as last time ›" : 'Press 1-5 ›', 'news'), ' ';
    my $service;
    while (1) {
        my $c = key();
        if ($c =~ /^[1-5]$/) { $service = $c; last }
        if ($c eq "\n" && $k->{service}) { $service = $k->{service}; last }
    }
    my ($sign, $name, $port) = @{$SERVICES[$service - 1]};
    print paint("$service  $sign $name", 'good'), "\n";
    my $forward;
    if ($port ne '') {
        $forward = "127.0.0.1:$port";
    } else {
        while (1) {
            my $last5 = $k->{forward} && ($k->{service} // 0) == 5;
            my $typed = line($last5
                ? "Which port: of this computer, such as 8080, or address:port of its network - Enter for $k->{forward}:"
                : 'Which port: of this computer, such as 8080, or address:port of its network:');
            $typed = $k->{forward} if $typed eq '' && $last5;
            last if defined($forward = target($typed // ''));
            say('💡', 'warn', 'A port, such as 8080, or an address and a port, such as 192.168.1.5:80');
        }
    }
    my ($p, $meet);
    while (1) {
        my $typed = line($k->{meet} ? 'The relay - Enter for ' . hidden($k->{meet}) . ':' : 'The relay, as its owner gave it, such as Tr7kQ2xZp4Lm9sWd👉router.example.org:40000👉:');
        $typed = $k->{meet} if $typed eq '' && $k->{meet};
        if ($p = point($typed // '')) {
            $meet = rest_of($p);
            $p->{key} //= $meet eq plain($k->{meet} // '') ? $k->{password} : undef;
            last;
        }
        say('💡', 'warn', "As its owner gave it - $LINES - or a name or an address, and :port when its owner gave one");
    }
    until (key_ok($p->{key})) {
        $p->{key} = line('Its password or key, 16 letters and digits:');
        say('💡', 'warn', 'The password of a relay, or a key of it, is 16 letters and digits') unless key_ok($p->{key});
    }
    # the token: Enter keeps what was last time, a token or none
    say('🎫', 'quiet', 'With a token only AdHoc Relay Client gets in, given the token too, and directly when the two can. Without one, any program of the client, through the relay');
    my $token;
    while (1) {
        my $typed = line(key_ok($k->{token}) ? 'The token - Enter for the one of last time, - for none, + for a new one:' : 'The token, 16 letters and digits - + for a new one, Enter for none:');
        $token = $typed eq '' ? (key_ok($k->{token}) ? $k->{token} : undef) : $typed eq '-' ? undef : $typed eq '+' ? new_token() : $typed;
        last if !defined $token || key_ok($token);
        say('💡', 'warn', 'A token is 16 letters and digits, as a key; + makes one');
    }
    $k->{service} = $service;
    $k->{forward} = $forward if $service == 5;
    $k->{meet} = pretty($meet); # kept as people see it: the emoji
    $k->{password} = $p->{key};
    $k->{token} = $token;
    save_kept($k);
    print "\n";
    return ($forward, $p->{key} . $meet, $token);
}

# ── the arguments, or the menu ──

my ($forward, $given, $TOKEN);
while (my $a = shift @ARGV) {
    if ($a eq '--forward') { $forward = target(shift(@ARGV) // '') or die "--forward <port> or <address:port>, such as 22 or 192.168.1.5:80\n" }
    elsif ($a eq '--meet') { $given = shift @ARGV }
    elsif ($a eq '--token') { $TOKEN = shift(@ARGV) // ''; die "--token <16 letters and digits>, such as K7QM2XHP9RTA4WZD\n" unless key_ok($TOKEN) }
    elsif ($a eq '--parse') { print parsed(shift(@ARGV) // ''), "\n"; exit 0 } # what it makes of a line: docs/lines.tsv
    elsif ($a eq '--vector') { print vector(split ' ', shift(@ARGV) // ''), "\n"; exit 0 } # the bytes it makes: docs/vectors.tsv
    else {
        print "perl adhoc-relay-server.pl [--meet <the line of the relay> --forward <port> | <address:port> [--token <token>]]\n",
            "  the line as its owner gave it: <password or key>👉<relay>[:40000]👉, or with the address read:\n",
            "  <key>🌐<key of reading>👉<keeper>:<its port>[🌐...]🌐<first port of the relay>👉 - or > @ for 👉 🌐\n",
            "  the token: 16 letters and digits; only AdHoc Relay Client, given it too, gets in - directly when the two can\n",
            "  with no arguments it asks, and keeps the answers beside it\n";
        exit 2;
    }
}

print "\n ", paint('AdHoc Relay', 'name'), paint(' · the server', 'news'), "\n ",
    paint('the client reaches a service of this server through a relay: no port forwarded on the routers', 'quiet'), "\n";
if (!defined $forward || !defined $given) {
    die "--meet and --forward go together\n" if defined $forward || defined $given;
    die "--token goes with --meet and --forward\n" if defined $TOKEN;
    die "no terminal to ask in: give --meet and --forward\n" unless -t STDIN;
    ($forward, $given, $TOKEN) = menu();
}
my $p = point($given);
die "--meet <the line of the relay>, $LINES\n" unless $p && key_ok($p->{key});
my $rdp = $forward =~ /:$RDP$/;

say('💤', 'warn', 'To connect later, this computer must stay on and awake while this runs: asleep, it lets nobody in, and a minute later the relay gives its port to others');
say('💤', 'warn', $^O eq 'darwin' ? 'macOS: System Settings > Energy, or Battery > Options: keep it from sleeping. The screen may go dark'
    : 'Linux: suspend never, in the settings of power; or systemd-inhibit perl adhoc-relay-server.pl. The screen may go dark');

# the server: said at once when nothing answers there; the meetings wait for it anyway
if (IO::Socket::INET->new(PeerAddr => $forward, Proto => 'tcp', Timeout => 2)) {
    say('🔌', 'good', "$forward answers: whoever comes is joined to it");
} elsif ($rdp) {
    say('⚠️', 'warn', "Nothing answers at $forward: no Remote Desktop server here. On Linux, xrdp");
} else {
    say('⚠️', 'warn', "Nothing answers at $forward yet: whoever comes waits for it");
}
if ($rdp) {
    say('🔑', 'warn', 'Whoever finds the port will try passwords: programs of the internet guess at every Remote Desktop they find, day and night');
    say('🔑', 'warn', 'The account you log in with needs a long password of its own, 16 characters or more, used nowhere else; not Administrator, admin or user');
}

# ── the meeting ──

# one socket for the requests and the reads: the NAT of this computer keeps one mapping for them. The knocks go from the port
# the dialing goes from: see `pick`
my $udp = IO::Socket::INET->new(Proto => 'udp', LocalAddr => '0.0.0.0') or die "UDP: $!\n";
my $sel = IO::Select->new($udp);
# 8 bytes of the random of the system: its id, and what goes with each read of the address - nothing perl makes up, which can
# be guessed
sub random8 {
    my $b = '';
    if (open my $r, '<:raw', '/dev/urandom') { read $r, $b, 8; close $r }
    die "No random bytes from /dev/urandom\n" if length $b != 8;
    return $b;
}
my $id = random8();
my $KEY = $p->{key};
utf8::downgrade($KEY);
# with a token, the key of a call of it: what the knocks carry after the key of the knocks, and a call begins with - the first 8
# bytes of SHA-256 of "adhoc-relay call" and the token. The token itself goes only to the client, the first bytes of each
# connection
utf8::downgrade($TOKEN) if defined $TOKEN;
my $CALL = defined $TOKEN ? substr(sha256("adhoc-relay call$TOKEN"), 0, 8) : undef;

# the id of a key, 8 bytes: what this server names its key by - the key itself never travels
sub kid { my $k = $_[0]; utf8::downgrade($k); substr(sha256("AdHoc Relay id$k"), 0, 8) }
# what a key says of some words: the first bytes of HMAC-SHA256, 8 unless asked
sub said { my ($words, $k, $n) = @_; utf8::downgrade($k); substr(hmac_sha256($words, $k), 0, $n // 8) }

# the address the relay sees this computer at, 4 bytes - a bind is made for it; none yet: 0.0.0.0. And the knock: the key of
# the knocks of the port, 16 bytes the key makes of the id, the port and that address - made at each bind
my ($as, $knock) = ("\0\0\0\0", '');

# The answer from `to` to what was sent there that `taken` takes, within a second; undef - none. What it does not take - of
# another length, not signed by the key - is passed over, and the wait goes on: a packet sent in the name of the relay by
# someone else, there before the answer, does not take its place
sub answer {
    my ($to, $taken) = @_;
    my ($port, $ip) = unpack_sockaddr_in($to);
    my $until = Time::HiRes::time() + 1;
    while ((my $left = $until - Time::HiRes::time()) > 0) {
        last unless $sel->can_read($left);
        my $from = recv($udp, my $got, 64, 0);
        next unless defined $from && $taken->($got);
        my ($fport, $fip) = unpack_sockaddr_in($from);
        return $got if $fport == $port && $fip eq $ip;
    }
    return undef;
}

# What this server says, each made in one place - for the relay, and for `--vector`. A bind: of the key, the id of this start
# and the address the relay sees this computer at, 4 bytes. The key of the knocks of a port: the port as its 2 bytes. A read:
# with 8 random bytes; and what the read key says of them and the 5 bytes answered - the address, the minutes
sub bind_packet { my ($k, $id, $as) = @_; kid($k) . $id . said("bind$id$as", $k) }
sub knock_key { my ($k, $id, $port, $as) = @_; said("knock$id$port$as", $k, 16) }
sub read_packet { kid($_[0]) . $_[1] }
sub read_said { my ($k, $nonce, $five) = @_; said("read$nonce$five", $k) }
# what the key says of an answer to a bind: made for another address - of the address the relay sees; bound - of the port, its 2
# bytes, that address and the times of the relay, 3 bytes
sub seen_said { my ($k, $id, $as) = @_; said("seen$id$as", $k) }
sub bound_said { my ($k, $id, $port, $as, $times) = @_; said("bound$id$port$as$times", $k) }

# `--vector "<what> <of what>"`: the bytes of a case of docs/vectors.tsv, hex - what any program that speaks to the relay makes
# of the same keys
sub vector {
    my ($what, $k, @a) = @_;
    my $out = ($what // '') eq 'kid' && @a == 0 ? kid($k)
        : $what eq 'bind' && @a == 2 ? bind_packet($k, pack('H*', $a[0]), inet_aton($a[1]))
        : $what eq 'knock' && @a == 3 ? knock_key($k, pack('H*', $a[0]), pack('n', $a[1]), inet_aton($a[2]))
        : $what eq 'read' && @a == 1 ? read_packet($k, pack('H*', $a[0]))
        : $what eq 'answer' && @a == 3 ? do { my $five = inet_aton($a[1]) . chr($a[2]); $five . read_said($k, pack('H*', $a[0]), $five) }
        : $what eq 'seen' && @a == 2 ? inet_aton($a[1]) . seen_said($k, pack('H*', $a[0]), inet_aton($a[1]))
        : $what eq 'bound' && @a == 6 ? do { my $told = pack('n', $a[1]) . inet_aton($a[2]) . pack('C3', @a[3 .. 5]); $told . bound_said($k, pack('H*', $a[0]), substr($told, 0, 2), substr($told, 2, 4), substr($told, 6)) }
        : die "--vector \"kid <key>\" | \"bind <key> <id> <address>\" | \"knock <key> <id> <port> <address>\" | \"read <key> <8 bytes>\" | \"answer <key> <8 bytes> <address> <minutes>\" | \"seen <key> <id> <address>\" | \"bound <key> <id> <port> <address> <knock> <dial> <rebind>\"\n";
    return unpack 'H*', $out;
}

# Where the relay is now: [ its address, packed; its first port; its name in the line for the client ]. Its name looked up
# again; or, of a changing address, read from its keepers in turn - an answer written within 2 minutes taken at once, else the
# freshest. A read: the id of the key of reading and 8 random bytes; the answer is taken only when that key signed it with them
# - the address of the relay from anyone else would send this server, and its binds, to another computer. undef - not found.
sub locate {
    unless ($p->{reads}) {
        my $ip = inet_aton($p->{host}) or return undef;
        return [$ip, $p->{port}, $p->{host}];
    }
    my $best;
    for my $r (@{$p->{reads}}) {
        my ($read, $keeper, $asks) = @$r;
        my $ip = inet_aton($keeper) or next;
        my $to = pack_sockaddr_in($asks, $ip);
        my $got;
        for (1 .. 3) {
            my $nonce = random8();
            send($udp, read_packet($read, $nonce), 0, $to);
            $got = answer($to, sub { length $_[0] == 13 && substr($_[0], 5) eq read_said($read, $nonce, substr($_[0], 0, 5)) });
            last if defined $got;
        }
        next unless defined $got;
        # the address, the minutes since the relay last wrote it; its port is of the line
        my ($at, $age) = unpack('a4 C', $got);
        my $found = [$at, $p->{port}, inet_ntoa($at), $age];
        return $found if $age <= 2;
        $best = $found if !$best || $age < $best->[3];
    }
    return $best;
}

# The times of the relay, as its answer to a bind says them: how often to knock, seconds - the relay keeps the port open `wait`
# seconds after a knock, 60 by default: two may be lost -; how long a try of dialing is, seconds - the system sends its SYN again
# within it, after 1, 3, 7 and 15 s, and the next try comes at once: the relay knows where the server waits a little longer than
# the longest time between two SYNs -; how often to bind anew, minutes. As they are by default till the first answer
my ($KNOCK, $TRY, $REBIND) = (20, 31, 30);

# A port of meeting bound at the relay, up to `tries` requests - 10 at the start; 3 while it waits: the relay forgets where the
# server dials from soon, and nothing dials meanwhile. A bind: the id of the key, the id of this start, and what the key says
# of "bind", that id and the address the relay sees this computer at. Made for another address, the relay answers the address
# - 4 bytes -, and the bind is made again for it; else the port, 2 bytes, the address and the times of the relay, 3 bytes.
# Either way with 8 bytes the key makes of the answer: one the key did not sign is not taken - it would send this server, and
# the line it gives to its clients, to a port of someone else. The same id gets the port it holds again. The key of the knocks
# is made anew with them. undef - no answer.
sub ask {
    my ($at, $tries) = @_;
    my $to = pack_sockaddr_in($at->[1], $at->[0]);
    # one request more than asked: the first may only learn the address
    for (0 .. $tries // 10) {
        send($udp, bind_packet($KEY, $id, $as), 0, $to);
        my $got = answer($to, sub {
            my $g = $_[0];
            length $g == 12 ? substr($g, 4) eq seen_said($KEY, $id, substr($g, 0, 4))
                : length $g == 17 && substr($g, 9) eq bound_said($KEY, $id, substr($g, 0, 2), substr($g, 2, 4), substr($g, 6, 3));
        }) // next;
        if (length $got == 12) { $as = substr($got, 0, 4); next }
        $as = substr($got, 2, 4);
        # a time of 0 would knock, dial or bind without end: as by default then
        my ($k, $t, $r) = unpack 'C3', substr($got, 6, 3);
        ($KNOCK, $TRY, $REBIND) = ($k || 20, $t || 31, $r || 30);
        $knock = knock_key($KEY, $id, substr($got, 0, 2), $as) . ($CALL // '');
        return unpack('n', $got);
    }
    return undef;
}

my $keepers = $p->{reads} ? join(', ', map { "$_->[1]:$_->[2]" } @{$p->{reads}}) : '';
my $at = locate();
until ($at) {
    die "The relay $p->{host}: no such address\n" unless $p->{reads};
    say('❌', 'bad', "No address of the relay from $keepers: a wrong key of reading, the relay has not written its address there yet, or this address is blocked for wrong keys. Again in 5 s");
    sleep 5;
    $at = locate();
}
my $port = ask($at);
unless ($port) {
    say('❌', 'bad', "No port of meeting from $at->[2]:$at->[1]: a wrong key, a wrong first port - the line of a fixed port has the first port of the relay too, copy it again - or this address is blocked for wrong keys");
    exit 1;
}

# The line for the client, in a box and in the clipboard, and how its program takes it.
sub show {
    my $host = $at->[2];
    my $line = "$host:$port";
    my $bar = '─' x (length($line) + 4);
    print "\n";
    say('📨', 'news', 'Send this line to whoever connects:');
    print '    ', paint("╭$bar╮", 'quiet'), "\n    ", paint('│  ', 'quiet'), paint($line, 'good'), paint('  │', 'quiet'), "\n    ", paint("╰$bar╯", 'quiet'), "\n";
    my $copied;
    for my $tool (['pbcopy'], ['wl-copy'], ['xclip', '-selection', 'clipboard'], ['xsel', '-ib']) {
        next unless grep { -x "$_/$tool->[0]" } split /:/, ($ENV{PATH} // '');
        next if $tool->[0] =~ /^x/ && !$ENV{DISPLAY};
        next if $tool->[0] eq 'wl-copy' && !$ENV{WAYLAND_DISPLAY};
        if (open my $c, '|-', @$tool) { print $c $line; $copied = close $c }
        last if $copied;
    }
    say('📋', 'good', 'It is in your clipboard already: just paste it into a message') if $copied;
    # with a token the program of the client dials AdHoc Relay Client, on its own computer: it listens at the port of meeting
    # there, unless told another
    if (defined $TOKEN) {
        # the first port of the relay, when it is not 40000: AdHoc Relay Client asks STUN there - as perl and as PowerShell take it
        my ($first, $windows) = $at->[1] == 40000 ? ('', '') : (" --first $at->[1]", " -First $at->[1]");
        say('🎫', 'news', "The token, with the line: $TOKEN - only AdHoc Relay Client gets in; a program that dials the line itself is cut off");
        say('🧩', 'news', "AdHoc Relay Client on the client: perl adhoc-relay-client.pl --meet $line --token $TOKEN --listen $port$first · Windows: adhoc-relay-client.cmd -Meet $line -Token $TOKEN -Listen $port$windows");
        ($host, $line) = ('127.0.0.1', "127.0.0.1:$port");
    }
    if ($rdp) { say('🖥️', 'news', "Remote Desktop Connection ( mstsc ) of the client: as the computer, $line") }
    elsif ($forward =~ /:22$/) { say('🔐', 'news', "On the client: ssh -p $port <user>\@$host") }
    elsif ($forward =~ /:80$/) { say('🌐', 'news', "A browser of the client: http://$line") }
    else { say('🔗', 'news', "A program of the client reaches $forward at $line") }
    print "\n";
}
show();
say('👀', 'wait', 'Waiting for whoever connects…');

# Each connection lives in a process of its own, gone with it: those that ended are taken off as the loop goes round, and counted
# - as many joined at once as MAX, no more: the port of meeting is open to anyone, and each one who comes and stays silent would
# hold a process and a connection to the service for ever
my ($MAX, $live) = (64, 0);
# a write to a connection that is gone is an error of that write, not the end of the process
$SIG{PIPE} = 'IGNORE';

# the local port the dialing goes from: kept till someone comes - the relay that moves too knows the server by it. The knocks
# go from a UDP socket bound to its number: a NAT that keeps the port shows the relay one port in both, and the relay knows the
# server by it - a client behind the same NAT is never taken for the server
my $from = 0;
my $knocker;
# the try of dialing the relay now: a process of a connection does not keep it open
my $trying;

# ── the direct way, with a token ──

# Where this server can be reached from its local port now, { pub, lan, v6 }, each [ address, port ] or undef; learnt at each new
# local port. The sockets of the knocks of the local ports before, 6 s each: the relay sends a call to where the server dialed it
# from up to 5 s before - it cannot change that from the path of a packet -, and they answer it there too. The client that
# called, where it is dialed - [ { how, to, sock, at, done } ] -, till `until`
my ($me, @old, @targets, $until);

# SO_REUSEADDR on a TCP socket of the local port, and with a token SO_REUSEPORT too where the system has it: the try of dialing
# the relay and the dialings of a client go from the one local port at once, and macOS lets two sockets bind one port only so
sub reuse {
    my ($s) = @_;
    setsockopt($s, SOL_SOCKET, SO_REUSEADDR, 1);
    eval { setsockopt($s, SOL_SOCKET, Socket::SO_REUSEPORT(), 1) } if $CALL;
    return 1;
}

# The address and the port the relay sees a UDP socket at, by STUN at its first port: a Binding Request of RFC 8489, the
# answer its XOR-MAPPED-ADDRESS, 32 bytes. Up to `tries` requests, `wait` seconds each. undef - no answer
sub stun {
    my ($u, $tries, $wait) = @_;
    my $to = pack_sockaddr_in($at->[1], $at->[0]);
    my $tx = random8() . substr(random8(), 0, 4);
    for (1 .. $tries) {
        send($u, "\x00\x01\x00\x00\x21\x12\xa4\x42$tx", 0, $to);
        my $end = Time::HiRes::time() + $wait;
        while ((my $left = $end - Time::HiRes::time()) > 0) {
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
    my $s = IO::Socket::INET->new(PeerAddr => inet_ntoa($at->[0]), PeerPort => $at->[1], Proto => 'udp') or return undef;
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

# Where this server can be reached from the local port of the UDP socket `u`: the public address and port, when its NAT keeps the
# local port - else none -, the LAN address, the IPv6 address. Two STUN requests of half a second: the knocks of this port wait
sub here {
    my ($u, $local) = @_;
    my $pub = stun($u, 2, 0.5);
    my $lan = lan_of();
    my $v6 = v6_of();
    return { pub => ($pub && $pub->[1] == $local ? $pub : undef), lan => ($lan ? [ $lan, $local ] : undef), v6 => ($v6 ? [ $v6, $local ] : undef) };
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

# The dialing of a target: one socket; a new one each 300 ms while nothing came back, and at once after a refusal. The first SYN
# of one may reach the router of the other before that router saw the SYN of its own side; the next one meets
sub punch {
    my ($t) = @_;
    if ($t->{sock} && Time::HiRes::time() - $t->{at} >= 0.3 && sent($t->{sock})) { close $t->{sock}; $t->{sock} = undef }
    return if $t->{sock};
    $t->{sock} = dial($t->{local}, @{ $t->{to} }) or return;
    $t->{at} = Time::HiRes::time();
}

# A local port for the knocks and the dialing both: free for UDP and for TCP. 0 - none now. With a token, where this server can
# be reached from it is learnt at once, and the socket of the knocks before answers calls 6 s more
sub pick {
    for (1 .. 20) {
        # bound by hand: IO::Socket::INET binds no port 0
        my $u = IO::Socket::INET->new;
        socket($u, PF_INET, SOCK_DGRAM, IPPROTO_UDP) && bind($u, pack_sockaddr_in(0, INADDR_ANY)) or next;
        my $p = (unpack_sockaddr_in(getsockname($u)))[0];
        socket(my $t, PF_INET, SOCK_STREAM, IPPROTO_TCP) or next;
        setsockopt($t, SOL_SOCKET, SO_REUSEADDR, 1);
        my $free = bind($t, pack_sockaddr_in($p, INADDR_ANY));
        close $t;
        next unless $free;
        if ($knocker && $CALL) { push @old, { sock => $knocker, until => Time::HiRes::time() + 6 } }
        elsif ($knocker) { close $knocker }
        $knocker = $u;
        $me = here($u, $p) if $CALL;
        return $from = $p;
    }
    return 0;
}


# The knock goes every KNOCK seconds, and at once at a new address, after a meeting, or when the port refused: the fewer packets
# with the key, the less there is to watch. A try of dialing waits up to TRY seconds, the next comes at once.
my $knocked = 0;
# The port of meeting refused 3 times in a row, knocked at each time: the relay may know the port no more - it started again, or the
# server knocked not for long. It is bound again then, with the same id: the same port while the relay knows it, else a new one.
# And a knock refused - the socket of the knocks hears it: the relay knows the key of the knocks, but from another address than
# this computer has now. Bound again at once, for where it is
my ($refusals, $lost) = (0, 0);

# With a token: one look, up to `wait` seconds, at the calls, the dialings of the client that called and the try of dialing the
# relay. A call - 38 bytes from the port of meeting, the key of a call first - is answered by the socket that heard it with
# where this server can be reached, and the client is dialed where it can be, 3 s; a dialing that connected is served as any
# connection - the token first. 1 - the try is ready; -1 - a knock refused: $lost; 0 - neither yet
sub direct {
    my ($tcp, $wait) = @_;
    # the connections that ended taken off here too: a try of dialing is long, and the count would wait for its end
    $live-- while $live > 0 && waitpid(-1, WNOHANG) > 0;
    my $now = Time::HiRes::time();
    for (grep { $_->{until} <= $now } @old) { close $_->{sock} }
    @old = grep { $_->{until} > $now } @old;
    if (@targets && $now >= $until) { close $_->{sock} for grep { $_->{sock} } @targets; @targets = () }
    punch($_) for grep { !$_->{done} } @targets;
    # a dialing goes on each 50 ms; else the calls are looked at each second at most, and the sockets of before let go
    my $most = @targets ? 0.05 : 1;
    $wait = $most if $wait > $most;
    my ($readable, $writable) = IO::Select->select(IO::Select->new($knocker, map { $_->{sock} } @old),
        IO::Select->new($tcp, map { $_->{sock} } grep { $_->{sock} } @targets), undef, $wait);
    for my $s (@{ $readable // [] }) {
        my $back = recv($s, my $got, 64, 0);
        # a refusal the socket of the knocks heard: the relay knows the key of the knocks from another address
        if (!defined $back) { if ($s == $knocker && $! == ECONNREFUSED) { ($lost, $knocked) = (1, 0); return -1 } next }
        next unless length $got == 38 && substr($got, 0, 8) eq $CALL && $me;
        send($s, encode($me), 0);
        close $_->{sock} for grep { $_->{sock} } @targets;
        @targets = map { +{ %$_, local => $from } } targets($me, decode(substr($got, 8)));
        $until = Time::HiRes::time() + 3;
        say('📞', 'quiet', @targets ? 'A client called: dialing it, ' . ways(@targets) : 'A client called: nowhere to dial it - it meets this server through the relay');
    }
    my $ready = 0;
    for my $s (@{ $writable // [] }) {
        if ($s == $tcp) { $ready = 1; next }
        my ($t) = grep { $_->{sock} && $_->{sock} == $s } @targets or next;
        $t->{sock} = undef;
        # refused, or no way there: dialed again at the next look, while the time lasts
        if (unpack('i', getsockopt($s, SOL_SOCKET, SO_ERROR) // pack('i', 0))) { close $s; next }
        $t->{done} = 1;
        $s->blocking(1);
        serve($s, 'directly, ' . ways($t));
    }
    return $ready;
}

# Waits up to `seconds` for a try of dialing to end - met, or refused -, knocking meanwhile as each knock is due: a try may be
# longer than the time between two knocks, and the NAT of this computer must keep the mapping of the knocks. A knock refused
# meanwhile - the socket of the knocks has it to read - ends the wait, with $lost. With a token the calls are answered meanwhile,
# and the client that called is dialed. True: the socket of the try is ready
sub waiting {
    my ($tcp, $seconds) = @_;
    my ($end, $sel) = (time + $seconds, IO::Select->new($tcp));
    while ((my $left = $end - time) > 0) {
        my $due = $knocked + $KNOCK - time;
        my $wait = $due < $left ? ($due > 0 ? $due : 0) : $left;
        if ($CALL) {
            my $ready = direct($tcp, $wait);
            return $ready > 0 if $ready;
        } else {
            return 1 if $sel->can_write($wait);
        }
        next if time - $knocked < $KNOCK;
        if (unpack('i', getsockopt($knocker, SOL_SOCKET, SO_ERROR) // pack('i', 0)) == ECONNREFUSED) { ($lost, $knocked) = (1, 0); return 0 }
        send($knocker, $knock, 0);
        $knocked = time;
    }
    return 0;
}

# Knocks at the port and dials it until someone comes or `until` - from one local port, so the NAT keeps one mapping: the
# connection. undef - nobody came by then.
sub once {
    my ($to, $until) = @_;
    while (time < $until) {
        $live-- while $live > 0 && waitpid(-1, WNOHANG) > 0;
        $from || pick() or do { say('❌', 'bad', "No free local port: $!"); sleep 1; next };
        # the clock of this computer put back: the knock is due now, not in an hour
        $knocked = 0 if $knocked > time;
        # connected to the port of meeting: a refusal of the relay comes back to this socket, and is read here - at each try of
        # dialing and at each knock
        connect($knocker, $to);
        if (unpack('i', getsockopt($knocker, SOL_SOCKET, SO_ERROR) // pack('i', 0)) == ECONNREFUSED) { ($lost, $knocked) = (1, 0); return undef }
        if (time - $knocked >= $KNOCK) {
            send($knocker, $knock, 0);
            $knocked = time;
        }
        my $started = time;
        # bound by hand: IO::Socket::INET binds no port 0, and then each try would go from another port. A local port that cannot
        # be bound: a new one, with its knock
        my $tcp = $trying = IO::Socket::INET->new;
        socket($tcp, PF_INET, SOCK_STREAM, IPPROTO_TCP) && reuse($tcp)
            && bind($tcp, pack_sockaddr_in($from, INADDR_ANY)) or do { say('❌', 'bad', "TCP: $!"); ($from, $knocked) = (0, 0); sleep 1; next };
        $from = (unpack_sockaddr_in(getsockname($tcp)))[0];
        $tcp->blocking(0);
        if (connect($tcp, $to) || $! == EINPROGRESS) {
            # a try whole, past `until` too: one cut short is one more try, and its SYNs - those of the start, a second apart, are
            # most of them. The look at the relay waits for its end
            my $ready = waiting($tcp, $TRY);
            if ($lost) { close $tcp; return undef }
            # a meeting that came at the end of the try is under way - the SYN of the client here, its answer not yet back -: closed
            # now, it would end the connection the client already has. It is given the time to come
            my $began = !$ready && meeting($tcp);
            $ready = IO::Select->new($tcp)->can_write(2) if $began;
            if ($ready) {
                my $err = $tcp->getsockopt(SOL_SOCKET, SO_ERROR);
                if (!$err) {
                    $tcp->blocking(1);
                    $knocked = 0; # the meeting closed the port: the next try knocks at once
                    $refusals = 0;
                    return $tcp;
                }
                # refused: the port is not open - the knock was lost, or came too late -: knocked again at once; 3 times in a row -
                # the relay may know the port no more. The network down is no refusal: no knock with the key each 2 s for it
                if ($err == ECONNREFUSED || $err == ECONNRESET) {
                    $knocked = 0;
                    if ($err == ECONNREFUSED && ++$refusals >= 3) { ($refusals, $lost) = (0, 1); close $tcp; return undef }
                }
            } else {
                $refusals = 0; # the port is open, the server waits at it: the row of refusals is over
                # A meeting began and did not come - a SYN of someone who went no further. For the relay it is a meeting all the
                # same: the port is closed, and what it keeps of it is of this local port - a new try from it would be taken for
                # that meeting still. A new local port, and its knock, as after a meeting
                ($from, $knocked) = (0, 0) if $began;
            }
        }
        # a connection of a meeting before still lives at this local port: it cannot dial the same port of the relay again
        elsif ($! == EADDRNOTAVAIL || $! == EADDRINUSE) { ($from, $knocked) = (0, 0) }
        close $tcp;
        # refused at once, or the network is down: a pause, not a storm of tries - 2 s at most, whatever the clock says
        my $rest = 2 - (time - $started);
        select(undef, undef, undef, $rest > 2 ? 2 : $rest) if $rest > 0;
    }
    return undef;
}

# The dialing has met someone and is finishing it: the state of the socket is SYN received or established. TCP_INFO of Linux, its
# first byte: 1 established, 3 SYN received; TCP_CONNECTION_INFO of macOS, its first byte: 4 established, 3 SYN received.
# Elsewhere - no.
sub meeting {
    my ($tcp) = @_;
    my ($opt, $made) = $^O eq 'linux' ? (11, 1) : $^O eq 'darwin' ? (0x106, 4) : return 0;
    my $info = getsockopt($tcp, IPPROTO_TCP, $opt) // return 0;
    my $state = unpack('C', $info);
    return defined $state && ($state == $made || $state == 3);
}

# A connection that met, joined to the service till both sides end: each end told the other.
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

# With a token, the connection begins with it - 16 bytes within 10 s -, or is cut off: a program that dials the port of meeting
# itself, a guesser, a way of the client other than the one it kept. `way`: how it came, through the relay or directly
sub join_to {
    my ($came, $way) = @_;
    if (defined $TOKEN) {
        my ($got, $end, $sel) = ('', time + 10, IO::Select->new($came));
        while (length $got < 16 && (my $left = $end - time) > 0) {
            $sel->can_read($left) or last;
            sysread($came, $got, 16 - length $got, length $got) or last;
        }
        return say('🚫', 'warn', "Someone came $way without the token: cut off") if $got ne $TOKEN;
    }
    my $there = IO::Socket::INET->new(PeerAddr => $forward, Proto => 'tcp', Timeout => 5)
        or return say('❌', 'bad', "Someone came; $forward: $!");
    say('✅', 'good', defined $TOKEN ? "Someone came $way: joined to $forward" : "Someone came: joined to $forward");
    setsockopt($_, IPPROTO_TCP, TCP_NODELAY, 1) for $came, $there;
    # Keepalive on the connection that met: after 60 s of silence, a probe each 10 s, 6 of them. A client that is gone without a
    # word - a laptop closed - is found, and its connection to the service ended; and a session that is silent stays known to
    # the NATs on the way and to the relay, which forget a silent connection in minutes
    setsockopt($came, SOL_SOCKET, SO_KEEPALIVE, 1);
    if ($^O eq 'linux') { setsockopt($came, IPPROTO_TCP, $_->[0], $_->[1]) for [4, 60], [5, 10], [6, 6] } # TCP_KEEPIDLE, _KEEPINTVL, _KEEPCNT
    elsif ($^O eq 'darwin') { setsockopt($came, IPPROTO_TCP, 0x10, 60) } # TCP_KEEPALIVE, seconds of silence
    pass_both($came, $there);
    say('👋', 'quiet', 'Gone, the one who came');
}

# A connection that met, joined to the service in a process of its own. The process keeps no other socket open: one it kept would
# live on after this one closed it - a try of dialing the relay would meet a client nobody serves
sub serve {
    my ($came, $way) = @_;
    if ($live >= $MAX) { say('⚠️', 'warn', "$MAX connections are joined already: one more turned away"); close $came; return }
    my $pid = fork;
    if (!defined $pid) { say('❌', 'bad', "fork: $!"); close $came; return }
    if ($pid == 0) {
        for ($udp, $knocker, $trying, map({ $_->{sock} } @old, @targets)) { close $_ if $_ && $_ != $came }
        join_to($came, $way);
        exit 0;
    }
    $live++;
    # how many are joined now, of those there may be: said from the second on
    say('👥', 'quiet', "$live of $MAX connections joined now") if $live > 1;
    close $came;
}

# the port of meeting is not sure at the address of now: asked again at the next look. And every REBIND minutes anyway: a relay that
# drops the SYN to a closed port, not refuses it, never says it forgot the port
my $unsure = 0;
my $look = time + 30;
my $renew = time + $REBIND * 60;
while (1) {
    # the clock of this computer put back: what was to be done later is due now, not in an hour
    $look = time if $look > time + 30;
    $renew = time if $renew > time + $REBIND * 60;
    my $came = once(pack_sockaddr_in($port, $at->[0]), $look);
    if ($came) {
        $from = 0;
        serve($came, 'through the relay');
        next;
    }
    # every 30 s, at the end of the try then: where the relay is now - a dynamic address moves; its name looked up again, or its
    # address read again
    $look = time + 30;
    my $now = locate();
    unless ($now) {
        say('⚠️', 'warn', $p->{reads} ? "No address of the relay from $keepers now: knocking on at the one of before" : "The relay $p->{host}: no such address now: knocking on at the one of before");
        # at the address of before: a port the relay there forgot is asked again all the same - the relay may be reached while
        # the one that keeps its address is not
        $now = $at;
    }
    my $moved = $now->[0] ne $at->[0] || $now->[1] != $at->[1];
    next unless $moved || $unsure || $lost || time >= $renew;
    ($lost, $renew) = (0, time + $REBIND * 60);
    my $was = "$at->[2]:$port";
    $at = $now;
    $knocked = 0;
    if (my $got = ask($at, 3)) {
        $port = $got;
        $unsure = 0;
    } else {
        $unsure = 1;
        say('⚠️', 'warn', "No port of meeting from $at->[2]:$at->[1] now: knocking at $port there, asking again in 30 s");
    }
    if ("$at->[2]:$port" ne $was) {
        say('🔀', 'news', $moved ? 'The relay moved: the line for the client is new' : 'A new port of meeting: the line for the client is new');
        show();
        say('👀', 'wait', 'Waiting for whoever connects…');
    } elsif ($moved) {
        say('🔀', 'quiet', 'The relay moved to ' . inet_ntoa($at->[0]) . ': the line for the client stays');
    }
}
