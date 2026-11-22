#!/usr/bin/perl
# AdHoc Relay: binds a port of meeting to a server. No key travels: a key is known by its id - the first 8 bytes of SHA-256 of
# "AdHoc Relay id" and the key -, and what is said with it is 8 bytes of HMAC-SHA256 made with the key.
#
# A bind, to the first port of the range, 24 bytes: the id of the key, the id of the server - 8 random bytes of its own - and
# HMAC of "bind", that id and the address this computer sees the server at, 4 bytes. Made for that address: the answer is a port
# of the others, 2 bytes, high first - one nobody holds, or the fixed port of the key -, the address, 4 bytes, the times of the
# server, 3 bytes - how often it knocks, seconds, how long a try of its dialing is, seconds, how often it binds again, minutes
# - and HMAC of "bound", the id, that port, that address and the times, 8 bytes; made for another: the address, and HMAC of
# "seen", the id and the address, and the server binds again with it. An answer is signed by the key of its request: nobody
# else answers in the name of this computer. The key of the knocks of the port - 16 bytes, HMAC of "knock", the id, the port
# and the address - goes into the rules with the port and the address, for two times `rebind`: the kernel opens the port at
# knocks with it from that address, and no program wakes for a knock. A server binds anew each `rebind` minutes. The rules let only
# the id of a key through, a few a second from an address; the port is taken in the kernel - `nft create`, which fails when the
# port is taken already - so no two servers get one port, whatever else adds there. A server that binds again - its answer lost,
# or behind another address now - gets its port again.
#
# The records, at the same port, 16 bytes each. A relay of a changing address writes: the id of its write key and HMAC of "write"
# and the address it is seen at - the record keeps the address the write came from when the two agree, and the answer is that
# address, 4 bytes, either way. A read: the id of a read key and 8 random bytes; the answer is the address, the minutes since the
# last write, and 8 bytes of HMAC of "read", those random bytes, the address and the minutes - 13 bytes: the server takes the
# answer of nobody else. And the reports: this computer writes its own address into the records of other relays, every 60 s, and
# at once when its address changes. What the records and the reports hold is in /run/adhoc-relay, for `adhoc-relay status`. The
# settings are those of /etc/adhoc-relay.conf, read again at SIGHUP, the keys that bind as `rules` wrote them, and the addresses
# of this computer.
#
# And STUN, at the same port: a Binding Request gets the address and the port it came from - a side and a client that meet
# directly learn there where the internet sees them. The calls themselves pass the kernel only, never this.

use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use Socket qw(inet_aton inet_ntoa sockaddr_in);
use POSIX ();
use Fcntl qw(:flock);

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

my %conf = (FIRST => 40000, LAST => 49999, KNOCK => 20, DIAL => 31, REBIND => 30);
open my $file, '<', '/etc/adhoc-relay.conf' or die "adhoc-relay: /etc/adhoc-relay.conf: $!\n";
while (<$file>) { $conf{$1} = $3 if /^\s*([A-Z]+)=(["']?)(.*?)\2\s*$/ }
close $file;
my ($first, $last) = @conf{qw(FIRST LAST)};
# The times of the servers, told in the answer to a bind: how often a server knocks, seconds; how long a try of its dialing is,
# seconds - the rules know where it waits by it -; how often it binds again, minutes - the key of its knocks lives two times
# that. Each a byte
my $rebind = $conf{REBIND};
my $times = pack 'C3', $conf{KNOCK}, $conf{DIAL}, $rebind;
my $STATE = '/run/adhoc-relay';

# the id of a key, 8 bytes: what a side names its key by
sub kid { substr(sha256("AdHoc Relay id$_[0]"), 0, 8) }
# what is said with a key: the first bytes of HMAC-SHA256 of the words, 8 unless asked
sub said { substr(hmac_sha256($_[0], $_[1]), 0, $_[2] // 8) }

# The keys that bind a port, as `rules` loaded them: by the id of each, the key, the mark its sides are noted with, its fixed
# port - 0: any -, the end of its last day - 0: never. The fixed ports: never given at random
my (%binder, %fixed);
if (open my $f, '<', "$STATE/binders") {
    while (<$f>) {
        my ($id, $mark, $port, $ends, $key) = split;
        next unless defined $key && $id =~ /^[0-9a-f]{16}$/;
        $binder{pack 'H*', $id} = { key => $key, mark => $mark, port => $port, ends => $ends };
        $fixed{$port} = 1 if $port;
    }
    close $f;
}

# the records: of each the address and when written; by the id of the write key and of each read key, the key and the name
my (%records, %writers, %readers);
for (split ' ', $conf{RECORDS} // '') {
    my ($name, $write, $read) = split /:/, $_, 3;
    next unless defined $write;
    $records{$name} = undef;
    $writers{kid($write)} = { key => $write, name => $name };
    $readers{kid($_)} = { key => $_, name => $name, ends => 0 } for grep { $_ ne '' } split /,/, $read // '';
}

# The users of the read keys, each with the end of its last day, 0 - never: the rules let an expired one through no more, and
# this checks it too. Only what a user with a limit carried is counted, and kept each hour.
# USERS: "<of>:<key>:<expires>:<limit>[:<name>] ..."
my $with_users;
for (split ' ', $conf{USERS} // '') {
    my ($of, $key, $expires, $limit) = split /:/;
    next unless defined $key;
    $with_users = 1 if $of =~ /^(?:password|\d+)$/ && ($limit // '') =~ /^0*[1-9]\d*$/;
    next unless $of =~ /^@(.+)$/ && exists $records{$1};
    $readers{kid($key)} = { key => $key, name => $1,
        ends => ($expires // '') =~ /^(\d{4})-(\d\d)-(\d\d)$/ ? POSIX::mktime(59, 59, 23, $3, $2 - 1, $1 - 1900) : 0 };
}
# a key of these is good now: not expired
sub good { !$_[0]{ends} || time <= $_[0]{ends} }

# a line with the signs of the keyboard: ✏️ !, 👀 ?, 👉 > - what makes an emoji coloured, or the colour of skin, left out. Bytes of
# UTF-8, as the file has them
sub plain {
    (my $line = $_[0] // '') =~ s/\xef\xb8\x8f|\xf0\x9f\x8f[\xbb-\xbf]//g;
    $line =~ s/\xe2\x9c\x8f/!/g;
    $line =~ s/\xf0\x9f\x91\x80/?/g;
    $line =~ s/\xf0\x9f\x91\x89/>/g;
    return $line =~ s/^\s+|\s+$//gr;
}

# the reports: where this computer writes its address. Each the line the relay of a fixed address gave for it,
# ✏️<write key>[👀<read key>]👉<host>:<port> - or ! ? > for the signs
my @reports;
for (split ' ', $conf{REPORTS} // '') {
    # a name or an address, of what names are made of: nothing a shell would take for its own, as the settings are its text too
    my ($key, $host, $at) = plain($_) =~ /^!([A-Za-z0-9]{16})(?:\?[A-Za-z0-9]{16})?>([A-Za-z0-9][A-Za-z0-9._-]*):(\d{1,5})$/
        or do { warn "adhoc-relay: the report '$_': not ✏️<write key>👀<read key>👉<address>:<port>\n"; next };
    # `as`: the address that relay saw this computer at last, 4 bytes - a write is made for it; none yet: 0.0.0.0
    push @reports, { host => $host, at => $at, write => $key, as => "\0\0\0\0", again => 0,
        sock => undef, local => undef, to => undef, tried => 0, sent => 0, answered => 0, seen => undef };
}

# a socket of the port of requests at the address; SO_REUSEADDR: the one of all the addresses and those of single ones share the
# port
sub at { IO::Socket::INET->new(LocalAddr => $_[0], LocalPort => $first, Proto => 'udp', ReuseAddr => 1) }

# An answer goes from the address its request came to: the kernel picks the address by the way back otherwise - a server in
# the LAN of this computer, asking at its public address, would get the answer from its LAN address, and take none. Perl of the
# system tells no address a request came to, so each IPv4 address of this computer has a socket of its own, and each socket
# answers from itself; the one of all the addresses takes those that come later, until SIGHUP
my $any = at('0.0.0.0') or die "adhoc-relay: the port $first: $!\n";
my @single;
my ($ip_cmd) = grep { -x } qw(/usr/sbin/ip /sbin/ip /usr/bin/ip /bin/ip);
if ($ip_cmd && open my $ip, '-|', $ip_cmd, '-4', '-o', 'addr', 'show') {
    while (<$ip>) {
        my $s = m{\binet\s+([\d.]+)/} ? at($1) : undef;
        push @single, $s if $s;
    }
    close $ip;
}
my $select = IO::Select->new($any, @single);
my %requests = map { $_ => 1 } $any, @single;
# `nft create` says so when a port is taken: that is no error here
open STDERR, '>', '/dev/null';
$SIG{HUP} = sub { exec $^X, $0 };
# perl blocks SIGHUP while its handler runs, and exec keeps the mask: unblocked, or the next reload would not reach this one
POSIX::sigprocmask(POSIX::SIG_UNBLOCK(), POSIX::SigSet->new(POSIX::SIGHUP()));

# a file of /run/adhoc-relay, whole: written beside, then put in place, so a reader never gets half of it
sub save {
    my ($name, $text) = @_;
    mkdir $STATE;
    open my $f, '>', "$STATE/$name.new" or return;
    print $f $text;
    close $f;
    rename "$STATE/$name.new", "$STATE/$name";
}

# the records: "<name> <address> <when written>"
sub save_records {
    save('records', join '', map { "$_ $records{$_}{address} $records{$_}{when}\n" } grep { $records{$_} } sort keys %records);
}

# the reports: "<host>:<port> <when sent> <when answered, 0 never> <address seen, or ->"
sub save_reports {
    save('reports', join '', map { "$_->{host}:$_->{at} $_->{sent} $_->{answered} " . ($_->{seen} // '-') . "\n" } @reports);
}

# the records kept by the `give` before this one: a reload starts it again, the records live on
if (open my $f, '<', "$STATE/records") {
    while (<$f>) {
        my @w = split;
        $records{$w[0]} = { address => $w[1], when => $w[2] } if @w == 3 && exists $records{$w[0]};
    }
    close $f;
}

# The sides bound, by their ids - 16 hex digits: the port of each, the id of its key, the address it bound from, the key of its
# knocks, its mark, and when that key ends in each of the 4 maps of the rules - `at`; `until` is the last of them.
# The rules keep the keys of the knocks in 4 maps, one for each `rebind` minutes in turn - `slot`: a side bound again is put into
# the map of now, its time full, and what it has in the maps of before ends by itself. An element there is gets no more time
# but by being taken out first, and `nft delete` reads every rule of the computer for that - ten times the work of an `add`; a
# side binds again each `rebind` minutes, and that is most of what `give` does. A map is used again four times that later:
# what it held, for two times that, is long gone.
# In /run/adhoc-relay/bound a line for each time a side was bound - "<id> <port> <id of the key> <address> <key of the knocks>
# <ends> <mark> <slot>" -, added at its end: not the whole file written at each bind. Written anew, short, at a start and when
# it grew long. A reload starts `give` again, the sides bound live on by it.
my (%bound, %owner, $journal);
my $noted = 0;
sub slot { int($_[0] / ($rebind * 60)) % 4 }
sub lines_of {
    my ($id) = @_;
    my ($b, $now) = ($bound{$id}, time);
    map { "$id $b->{port} $b->{kid} $b->{addr} $b->{knock} $b->{at}[$_] $b->{mark} $_\n" } grep { $b->{at}[$_] > $now } 0 .. 3;
}
sub save_bound {
    close $journal if $journal;
    save('bound', join '', map { lines_of($_) } sort keys %bound);
    $noted = 0;
    undef $journal unless open $journal, '>>', "$STATE/bound";
    if ($journal) { my $o = select $journal; $| = 1; select $o }
}
# the side was bound a moment ago: its line
sub note_bound {
    my ($id) = @_;
    return save_bound() if !$journal || ++$noted > 1000 + 2 * keys %bound;
    my $b = $bound{$id};
    print $journal "$id $b->{port} $b->{kid} $b->{addr} $b->{knock} $b->{at}[$b->{slot}] $b->{mark} $b->{slot}\n";
}
# what the map of a slot holds of a side: its key of the knocks with the port and the address, and without the address
sub held { my ($b, $s) = @_; ("bound$s { $b->{port} . $b->{addr} . 0x$b->{knock}", "bound_any$s { $b->{port} . 0x$b->{knock}") }

# The lock of the ports given: `rules load` takes it while it reads what the table holds and puts the new table in its place - a
# port given in that moment would be of neither, its server answered and the port forgotten. Taken here, on the file itself: no
# `flock` started for each command
mkdir $STATE;
my $lock;
open $lock, '>>', "$STATE/lock" or undef $lock;
sub nft {
    flock $lock, LOCK_EX if $lock;
    my $ok = system('nft', join '; ', @_) == 0;
    flock $lock, LOCK_UN if $lock;
    return $ok;
}

# A side that binds again and changes nothing - the same port, address, key of the knocks and user, its key alive in the rules
# still -: answered at once, and its key goes into the map of now later, with the others - one nft for all that came in
# LATER s. Each start of nft is work of its own: with thousands of servers binding again every `rebind` minutes, one for each
# was most of what `give` did. The side loses nothing meanwhile: its key lives on where it is, half its time at least. By id: a
# side that binds twice meanwhile is added once. In the map of now already - bound twice in one `rebind` -: nothing to add, an
# element there keeps the time it has
use constant LATER => 10;
my (%later, $later_since);
# the keys put off, into the rules now: all in one nft. One that fails - an element gone, the rules loaded anew meanwhile -: each
# side alone then
sub renew_now {
    my %due = %later;
    %later = ();
    my $commands = sub {
        my ($b, $l) = @_;
        my ($with, $any) = held($b, $l->{s});
        ("add element ip adhoc_relay given { $b->{port} }", "add element ip adhoc_relay $with timeout $l->{left}s : $l->{mark} }",
            "add element ip adhoc_relay $any timeout $l->{left}s }");
    };
    my @all = map { $bound{$_} ? $commands->($bound{$_}, $due{$_}) : () } sort keys %due;
    my $together = @all && nft(@all);
    for my $id (sort keys %due) {
        my ($b, $l) = ($bound{$id}, $due{$id});
        next unless $b && ($together || nft($commands->($b, $l)));
        $b->{at}[$l->{s}] = $l->{until} if $b->{at}[$l->{s}] < $l->{until};
        my $until = 0;
        $_ > $until and $until = $_ for @{$b->{at}};
        @$b{qw(until slot)} = ($until, $l->{s});
        note_bound($id);
    }
}
sub renew_later {
    my ($id, $b, $key) = @_;
    my $now = time;
    my $s = slot($now);
    my $left = $rebind * 120;
    $left = $key->{ends} - $now if $key->{ends} && $key->{ends} - $now < $left;
    return if $b->{at}[$s] > $now || $left < 1;
    $later_since = $now unless %later;
    $later{$id} = { s => $s, left => $left, until => $now + $left, mark => $key->{mark} };
    renew_now() if keys(%later) >= 150;
}

# The port is of this side now: whoever held it before - its knocks long ended - holds it no more. With `rules`: its keys of
# knocks that live still are taken out of the rules too - a knock of it would open a port of another. Not a fixed port: every
# server of its key binds it.
sub own {
    my ($id, $port, $rules) = @_;
    return if $fixed{$port};
    my $o = $owner{$port};
    if (defined $o && $o ne $id && $bound{$o} && $bound{$o}{port} == $port) {
        if ($rules) {
            my $now = time;
            for my $s (grep { $bound{$o}{at}[$_] > $now } 0 .. 3) {
                my ($with, $any) = held($bound{$o}, $s);
                nft("delete element ip adhoc_relay $with }", "delete element ip adhoc_relay $any }");
            }
        }
        delete $bound{$o};
    }
    $owner{$port} = $id;
}

# Those of before: one whose key is no more - taken away, changed, its day over - or binds another port now is taken out of the
# rules at once; one whose key has another mark now - its user got a limit, or the direct path only - is put there anew with it.
# One command for them all
if (open my $f, '<', "$STATE/bound") {
    my $now = time;
    while (<$f>) {
        my ($id, $port, $kid, $addr, $knock, $until, $mark, $slot) = split;
        next unless defined $mark && $until > $now;
        my $b = $bound{$id};
        # another port, address or key of knocks than its lines before: bound anew since
        $b = $bound{$id} = { port => $port, kid => $kid, addr => $addr, knock => $knock, mark => $mark, until => 0, at => [0, 0, 0, 0] }
            unless $b && $b->{port} == $port && $b->{addr} eq $addr && $b->{knock} eq $knock;
        # a line with no slot is of a `give` before the maps: nothing of it is in the rules, the side keeps its port
        $b->{at}[$slot] = $until if defined $slot && $slot =~ /^[0-3]$/;
        $b->{until} = $until if $until > $b->{until};
        $b->{mark} = $mark;
        own($id, $port);
    }
    close $f;
    my @cmd;
    for my $id (keys %bound) {
        my $b = $bound{$id};
        my $key = $binder{pack 'H*', $b->{kid}};
        my @live = grep { $b->{at}[$_] > $now } 0 .. 3;
        if (!$key || !good($key) || ($key->{port} && $key->{port} != $b->{port})) {
            for my $s (@live) { my ($with, $any) = held($b, $s); push @cmd, "delete element ip adhoc_relay $with }", "delete element ip adhoc_relay $any }" }
            delete $owner{$b->{port}} if ($owner{$b->{port}} // '') eq $id;
            delete $bound{$id};
            next;
        }
        if ($key->{mark} ne $b->{mark}) {
            for my $s (@live) {
                my ($with) = held($b, $s);
                my $left = $b->{at}[$s] - $now;
                push @cmd, "delete element ip adhoc_relay $with }", "add element ip adhoc_relay $with timeout ${left}s : $key->{mark} }";
            }
            $b->{mark} = $key->{mark};
        }
    }
    # one of them gone from the rules a moment ago fails the command whole: each by itself then
    if (@cmd && !nft(@cmd)) { nft($_) for @cmd }
}
save_bound();

# The side is bound: the key of its knocks in the map of now, with its port and the address, for two times `rebind` - or till
# the last day of its key ends. `how`: 'create' - the port is taken in the kernel, when nobody holds it: `nft create` fails when
# it is taken; 'add' - the port is its own already. Its element of this map, there already - bound twice in one `rebind` -,
# keeps the time it has: no less than one `rebind` more than the side needs till it binds again
sub bind_side {
    my ($id, $b, $key, $how) = @_;
    my $now = time;
    my $time = $rebind * 120;
    $time = $key->{ends} - $now if $key->{ends} && $key->{ends} - $now < $time;
    return 0 if $time < 1;
    my $s = slot($now);
    my ($with, $any) = held($b, $s);
    nft("$how element ip adhoc_relay given { $b->{port} }", "add element ip adhoc_relay $with timeout ${time}s : $key->{mark} }",
        "add element ip adhoc_relay $any timeout ${time}s }") or return 0;
    my $was = $bound{$id};
    # the same side as before: what it has in the other maps lives on to its end
    my $at = $was && $was->{knock} eq $b->{knock} && $was->{port} == $b->{port} && $was->{addr} eq $b->{addr} ? $was->{at} : [0, 0, 0, 0];
    $at->[$s] = $now + $time unless $at->[$s] > $now;
    my $until = 0;
    $_ > $until and $until = $_ for @$at;
    $bound{$id} = { %$b, until => $until, mark => $key->{mark}, at => $at, slot => $s };
    return 1;
}

# A port of meeting nobody holds, bound to the side; undef - there is none. A few picks at random first: with most of the range
# free the first is free, and nobody tells the next port from the last. None of them free - the range is nearly full -: the
# ports given are read from the kernel once - it alone knows them, they end there by themselves -, and a free one is taken of
# those left, from a place picked at random: a port there is is found
sub give {
    my ($id, $b, $key) = @_;
    my $range = $last - $first;
    # taken: whoever held this port before, its knocks long ended, holds it no more
    my $try = sub {
        $b->{port} = $_[0];
        $b->{knock} = $b->{make}->($_[0]);
        bind_side($id, $b, $key, 'create') or return 0;
        own($id, $_[0], 1);
        return 1;
    };
    for (1 .. 8) {
        my $pick = $first + 1 + int rand($range);
        return $pick if !$fixed{$pick} && $try->($pick);
    }
    my %taken = map { $_ => 1 } `nft list set ip adhoc_relay given 2>/dev/null` =~ /(\d+) (?:timeout \S+ )?expires/g;
    my $from = int rand($range);
    # one that was free a moment ago may be taken by now - by another `give`, by a load: a few tries, no more
    my $tried = 0;
    for my $i (0 .. $range - 1) {
        my $pick = $first + 1 + ($from + $i) % $range;
        next if $fixed{$pick} || $taken{$pick};
        last if $tried++ >= 8;
        return $pick if $try->($pick);
    }
    return undef;
}

# a request that came by the socket: the answer, or undef
sub request {
    my ($got, $from) = @_;
    my ($port_from, $address) = sockaddr_in($from);
    if (length($got) == 20 && substr($got, 0, 8) eq "\x00\x01\x00\x00\x21\x12\xa4\x42") {
        # a Binding Request of STUN, RFC 8489: a Binding Success Response with the address and the port it came from,
        # XOR-MAPPED-ADDRESS - 32 bytes
        return "\x01\x01\x00\x0c" . substr($got, 4, 16) . "\x00\x20\x00\x08\x00\x01" . pack('n', $port_from ^ 0x2112)
            . ($address ^ "\x21\x12\xa4\x42");
    }
    if (length($got) == 24) {
        # a bind: the id of a key that binds, the id of the side, and what the key says of "bind", that id and the address
        my $key = $binder{substr($got, 0, 8)} or return undef;
        return undef unless good($key);
        my $side = substr($got, 8, 8);
        # made for another address - the side does not know yet where it is seen, or its NAT changed it: told where
        return $address . said("seen$side$address", $key->{key}) if substr($got, 16) ne said("bind$side$address", $key->{key});
        my $id = unpack 'H*', $side;
        my $b = { kid => unpack('H*', substr($got, 0, 8)), addr => inet_ntoa($address),
            make => sub { unpack 'H*', said("knock$side" . pack('n', $_[0]) . $address, $key->{key}, 16) } };
        my $was = $bound{$id};
        # the port: the fixed one of the key; the one the side holds - bound again, from this address or another; a new one
        my $port = $key->{port} || ($was && $was->{kid} eq $b->{kid} && !$fixed{$was->{port}} ? $was->{port} : 0);
        # bound again, nothing changed - the key of its knocks is of the id, the port, the address and the key, the same all: its
        # key into the rules later, with others
        if ($port && $was && $was->{port} == $port && $was->{addr} eq $b->{addr} && $was->{mark} eq $key->{mark} && $was->{until} > time) {
            renew_later($id, $was, $key);
        } else {
            if ($port) {
                $b->{port} = $port;
                $b->{knock} = $b->{make}->($port);
                # its own port, or free since it stopped knocking: its again. Given to another meanwhile: a new one
                $port = 0 unless bind_side($id, $b, $key, $key->{port} || ($was && $was->{until} > time) ? 'add' : 'create');
            }
            $port ||= $key->{port} ? 0 : give($id, $b, $key) or return undef;
            delete $bound{$id}{make};
            # the ids of the sides that never came back are forgotten: their keys of knocks ended in the rules by themselves
            if (keys(%bound) > 2 * ($last - $first)) { my $now = time; delete $bound{$_} for grep { $bound{$_}{until} <= $now } keys %bound }
            note_bound($id);
        }
        my $told = pack('n', $port) . $address . $times;
        return $told . said("bound$side$told", $key->{key});
    }
    return undef unless length($got) == 16;
    my $by = substr($got, 0, 8);
    if (my $w = $writers{$by}) {
        # a write: the record takes the address it came from, when it was made for that address; the answer is the address, and
        # what the write key says of "seen" and it
        if (substr($got, 8) eq said("write$address", $w->{key})) {
            $records{$w->{name}} = { address => inet_ntoa($address), when => time };
            save_records();
        }
        return $address . said("seen$address", $w->{key});
    }
    if (my $r = $readers{$by}) {
        # a read: the address and the minutes since the last write - none while the record has none -, and what the read key
        # says of them and of the 8 bytes that came
        return undef unless good($r);
        my $rec = $records{$r->{name}} or return undef;
        my $minutes = int((time - $rec->{when}) / 60);
        my $answer = inet_aton($rec->{address}) . pack('C', $minutes > 255 ? 255 : $minutes);
        return $answer . said('read' . substr($got, 8) . $answer, $r->{key});
    }
    return undef;
}

# the address this computer writes from to the relay of a report, as the kernel picks it now: a socket connected there, no
# packet sent; undef - no way there now
sub local_of {
    my ($r) = @_;
    return undef unless $r->{addr};
    my $s = IO::Socket::INET->new(PeerAddr => $r->{addr}, PeerPort => $r->{at}, Proto => 'udp') or return undef;
    my $here = $s->sockhost;
    close $s;
    return $here;
}

# a report written: its name looked up anew when asked, a new socket when the way there changed - another address of this
# computer, or of that relay
sub write_report {
    my ($r, $look) = @_;
    $r->{tried} = time;
    if ($look || !$r->{addr}) {
        my $packed = inet_aton($r->{host});
        $r->{addr} = inet_ntoa($packed) if $packed;
    }
    my $here = local_of($r) or return;
    if (!$r->{sock} || $here ne ($r->{local} // '') || $r->{addr} ne ($r->{to} // '')) {
        if ($r->{sock}) { $select->remove($r->{sock}); close $r->{sock} }
        $r->{sock} = IO::Socket::INET->new(PeerAddr => $r->{addr}, PeerPort => $r->{at}, Proto => 'udp') or return;
        $select->add($r->{sock});
        $r->{local} = $here;
        $r->{to} = $r->{addr};
    }
    # the id of the write key, and what the key says of "write" and the address this computer is seen at there
    $r->{sock}->send(kid($r->{write}) . said("write$r->{as}", $r->{write}));
    $r->{sent} = time;
    save_reports();
}

write_report($_, 1) for @reports;
save_reports();
save_records();

# what the meetings of the users of ports carried is kept each hour - `rules save` writes it only when it changed: a computer
# that loses its power loses an hour of it at most. No users of ports: never woken for it
my $kept = time;

while (1) {
    # woken each 2 s at most when there are reports: has the address changed, is one due; and when the keys put off are due
    my $wait = @reports ? 2 : $with_users ? 3600 : undef;
    if (%later) {
        my $due = $later_since + LATER - time;
        $due = 0 if $due < 0;
        $wait = $due if !defined $wait || $due < $wait;
    }
    for my $udp ($select->can_read($wait)) {
        if ($requests{$udp}) {
            my $from = $udp->recv(my $got, 64) or next;
            my $answer = request($got, $from);
            $udp->send($answer, 0, $from) if defined $answer;
            next;
        }
        # the answer to a report: the address this computer wrote from, as that relay saw it - signed by the write key, or it
        # is of nobody
        my ($r) = grep { ($_->{sock} // 0) == $udp } @reports or next;
        defined $udp->recv(my $got, 16) or next;
        next unless length $got == 12 && substr($got, 4) eq said('seen' . substr($got, 0, 4), $r->{write});
        $got = substr($got, 0, 4);
        $r->{answered} = time;
        $r->{seen} = inet_ntoa($got);
        save_reports();
        # seen at another address than the write was made for: written again, for that one - once in 2 s at most
        if ($got ne $r->{as} && time - $r->{again} >= 2) {
            @$r{qw(as again)} = ($got, time);
            $r->{sock}->send(kid($r->{write}) . said("write$r->{as}", $r->{write}));
        }
    }
    renew_now() if %later && time - $later_since >= LATER;
    my $now = time;
    if ($with_users && $now - $kept >= 3600) { $kept = $now; system('/usr/libexec/adhoc-relay/rules', 'save') }
    for my $r (@reports) {
        # each 60 s; its name looked up again only when the write before got no answer - that relay may have moved, and a look-up
        # that finds no DNS holds the requests for a port meanwhile. At once when this computer writes from another address now -
        # not while it has no way there at all: the name is not looked up each 2 s then
        if ($now - $r->{tried} >= 60) { write_report($r, $r->{answered} < $r->{sent}) }
        elsif ($r->{local}) {
            my $here = local_of($r);
            write_report($r, 0) if $here && $here ne $r->{local};
        }
    }
}
