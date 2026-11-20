#!/usr/bin/perl
# AdHoc Relay: gives the server a port of meeting. It sends the password, 16 characters, and its id, 8 random bytes of its own, to
# the first port of the range; the answer is a port of the others, 2 bytes, high first, given to that id: only knocks with it open
# the port, from whatever address. The rules of the kernel let only the right password through, a few a second from an address;
# the port is taken in the kernel - `nft create`, which fails when the port is taken already - so no two servers get one port,
# whatever else adds there. A server that asks again with an id that holds a port - its answer lost, or this computer at another
# address now - gets that port. A fixed port is never given: it is its key's.
#
# The records, at the same port: a relay of a changing address writes its write key, 16 bytes, and the record keeps the
# address the write came from - the answer is that address, 4 bytes, as seen here; a read key, 16 bytes, gets the address and the
# minutes since the last write, 5 bytes - the port its servers have in their lines. And the reports: this computer writes its own address into the records of
# other relays, every 60 s, and at once when its address changes. What the records and the reports hold is in
# /run/adhoc-relay, for `adhoc-relay status`. The settings are those of /etc/adhoc-relay.conf, read again at SIGHUP, and the addresses
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

my %conf = (FIRST => 40000, LAST => 49999);
open my $file, '<', '/etc/adhoc-relay.conf' or die "adhoc-relay: /etc/adhoc-relay.conf: $!\n";
while (<$file>) { $conf{$1} = $3 if /^\s*([A-Z]+)=(["']?)(.*?)\2\s*$/ }
close $file;
my ($password, $first, $last) = @conf{qw(PASSWORD FIRST LAST)};
my $STATE = '/run/adhoc-relay';

# the fixed ports: never given at random
my %fixed = map { /^(\d+):/ ? ($1 => 1) : () } split ' ', $conf{FIXED} // '';

# the records: of each the address and when written; by the write key and by each read key, its name
my (%records, %writers, %readers);
for (split ' ', $conf{RECORDS} // '') {
    my ($name, $write, $read) = split /:/, $_, 3;
    next unless defined $write;
    $records{$name} = undef;
    $writers{$write} = $name;
    $readers{$_} = $name for grep { $_ ne '' } split /,/, $read // '';
}

# The users of the password and of the read keys, each with the end of its last day, 0 - never: the rules let an expired one
# through no more, and this checks it too - a request on a connection conntrack knows passes the rules unchecked.
# USERS: "<of>:<key>:<expires>:<limit>[:<name>] ..."
my %passwords = ($password => 1);
my (%ends, $with_users);
for (split ' ', $conf{USERS} // '') {
    my ($of, $key, $expires) = split /:/;
    next unless defined $key;
    if ($of eq 'password') { $passwords{$key} = 1; $with_users = 1 }
    elsif ($of =~ /^@(.+)$/ && exists $records{$1}) { $readers{$key} = $1 }
    elsif ($of =~ /^\d+$/) { $with_users = 1; next }
    else { next }
    $ends{$key} = ($expires // '') =~ /^(\d{4})-(\d\d)-(\d\d)$/ ? POSIX::mktime(59, 59, 23, $3, $2 - 1, $1 - 1900) : 0;
}
# a key of these is good now: not expired
sub good { !$ends{$_[0]} || time <= $ends{$_[0]} }

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
    my ($key, $host, $at) = plain($_) =~ /^!([A-Za-z0-9]{16})(?:\?[A-Za-z0-9]{16})?>([^\s:@=,!?>]+):(\d+)$/
        or do { warn "adhoc-relay: the report '$_': not ✏️<write key>👀<read key>👉<address>:<port>\n"; next };
    push @reports, { host => $host, at => $at, write => $key,
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

# the ports given, by the id they are given to - 16 hex digits, without the zeros in front, as nft shows it: what this `give`
# gave, and what the kernel held at its start. Each is checked in the kernel when its id asks again: a port its side stopped knocking
# at is given to others in time. So a request lists no set: an id never seen gets a port at once
my %given_to;
sub learn {
    %given_to = ();
    my $all = `nft list set ip adhoc_relay owned 2>/dev/null`;
    while ($all =~ /(\d+) \. 0x([0-9a-f]+)/g) {
        my ($port, $id) = ($1, $2);
        $id =~ s/^0+//;
        $given_to{$id} = $port;
    }
}
learn();

# the port of meeting the id holds, 16 hex digits, as the kernel has it; undef - none
sub held {
    my ($id) = @_;
    (my $want = $id) =~ s/^0+//;
    my $port = $given_to{$want};
    return $port if defined $port && system("nft get element ip adhoc_relay owned '{ $port . 0x$id }' >/dev/null 2>&1") == 0;
    delete $given_to{$want};
    return undef;
}

# a port of meeting nobody holds, given to the id, 16 hex digits; undef when 16 picks found none free. The ids of the sides that
# never came back are forgotten when there are more of them than ports: the kernel is asked again then
sub give {
    my ($id) = @_;
    for (1 .. 16) {
        my $port = $first + 1 + int rand($last - $first);
        next if $fixed{$port};
        next if system('nft', "create element ip adhoc_relay given { $port }; add element ip adhoc_relay owned { $port . 0x$id }") != 0;
        learn() if keys(%given_to) > $last - $first;
        (my $want = $id) =~ s/^0+//;
        $given_to{$want} = $port;
        return $port;
    }
    return undef;
}

# a request that came by the socket: the answer, or undef
sub request {
    my ($got, $from) = @_;
    my ($port_from, $address) = sockaddr_in($from);
    # on a connection conntrack knows already the rules check no key: it is checked here
    if (length($got) == 20 && substr($got, 0, 8) eq "\x00\x01\x00\x00\x21\x12\xa4\x42") {
        # a Binding Request of STUN, RFC 8489: a Binding Success Response with the address and the port it came from,
        # XOR-MAPPED-ADDRESS - 32 bytes
        return "\x01\x01\x00\x0c" . substr($got, 4, 16) . "\x00\x20\x00\x08\x00\x01" . pack('n', $port_from ^ 0x2112)
            . ($address ^ "\x21\x12\xa4\x42");
    }
    if (length($got) == 24 && $passwords{substr($got, 0, 16)} && good(substr($got, 0, 16))) {
        # a port of meeting
        my $id = unpack("H*", substr($got, 16));
        my $port = held($id) // give($id);
        return defined $port ? pack('n', $port) : undef;
    }
    if (length($got) == 16 && exists $writers{$got}) {
        # a write: the record takes the address it came from
        $records{$writers{$got}} = { address => inet_ntoa($address), when => time };
        save_records();
        return $address;
    }
    if (length($got) == 16 && exists $readers{$got} && good($got)) {
        # a read: the address and the minutes since the last write - none while the record has none
        my $r = $records{$readers{$got}} or return undef;
        my $minutes = int((time - $r->{when}) / 60);
        return inet_aton($r->{address}) . pack('C', $minutes > 255 ? 255 : $minutes);
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
    $r->{sock}->send($r->{write});
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
    # woken each 2 s at most when there are reports: has the address changed, is one due
    for my $udp ($select->can_read(@reports ? 2 : $with_users ? 3600 : undef)) {
        if ($requests{$udp}) {
            my $from = $udp->recv(my $got, 64) or next;
            my $answer = request($got, $from);
            $udp->send($answer, 0, $from) if defined $answer;
            next;
        }
        # the answer to a report: the address this computer wrote from, as that relay saw it
        my ($r) = grep { ($_->{sock} // 0) == $udp } @reports or next;
        defined $udp->recv(my $got, 16) or next;
        next unless length $got == 4;
        $r->{answered} = time;
        $r->{seen} = inet_ntoa($got);
        save_reports();
    }
    my $now = time;
    if ($with_users && $now - $kept >= 3600) { $kept = $now; system('/usr/libexec/adhoc-relay/rules', 'save') }
    for my $r (@reports) {
        # each 60 s, its name looked up again; at once when this computer writes from another address now - not while it has
        # no way there at all: the name is not looked up each 2 s then
        if ($now - $r->{tried} >= 60) { write_report($r, 1) }
        elsif ($r->{local}) {
            my $here = local_of($r);
            write_report($r, 0) if $here && $here ne $r->{local};
        }
    }
}
