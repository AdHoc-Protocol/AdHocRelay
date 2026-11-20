#!/usr/bin/ucode
// AdHoc Relay: gives the server a port of meeting. It sends the password, 16 characters, and its id, 8 random bytes of its own, to
// the first port of the range; the answer is a port of the others, 2 bytes, high first, given to that id: only knocks with it open
// the port, from whatever address. The rules of the kernel let only the right password through, a few a second from an address;
// the port is taken in the kernel - `nft create`, which fails when the port is taken already - so no two servers get one port,
// whatever else adds there. A server that asks again with an id that holds a port - its answer lost, or this router at another
// address now - gets that port. A fixed port is never given: it is its key's.
//
// The records, at the same port: a relay of a changing address writes its write key, 16 bytes, and the record keeps the
// address the write came from - the answer is that address, 4 bytes, as seen here; a read key, 16 bytes, gets the address and the
// minutes since the last write, 5 bytes - the port its servers have in their lines. And the reports: this router writes its own address into the records of
// other relays, every 60 s, and at once when its address changes. What the records and the reports hold is in
// /tmp/adhoc-relay, for the page. The settings are those of /etc/config/adhoc-relay; procd starts this again when they change.
//
// And STUN, at the same port: a Binding Request gets the address and the port it came from - a side and a client that meet
// directly learn there where the internet sees them. The calls themselves pass the kernel only, never this.

import * as socket from 'socket';
import { cursor } from 'uci';
import { rand, srand } from 'math';
import { popen, readfile, writefile, rename, mkdir } from 'fs';

const ctx = cursor();
const main = ctx.get_all('adhoc-relay', 'main') ?? {};
const password = main.password, first = +(main.first ?? 40000), last = +(main.last ?? 49999);
const STATE = '/tmp/adhoc-relay';

// a line with the signs of the keyboard: ✏️ !, 👀 ?, 👉 > - what makes an emoji coloured, or the colour of skin, left out
function plain(line) {
	line = line ?? '';
	for (let s in [ '\xef\xb8\x8f', '\xf0\x9f\x8f\xbb', '\xf0\x9f\x8f\xbc', '\xf0\x9f\x8f\xbd', '\xf0\x9f\x8f\xbe', '\xf0\x9f\x8f\xbf' ])
		line = replace(line, s, '');
	return trim(replace(replace(replace(line, '\xe2\x9c\x8f', '!'), '\xf0\x9f\x91\x80', '?'), '\xf0\x9f\x91\x89', '>'));
}

// the fixed ports: never given at random
let fixed = {};
ctx.foreach('adhoc-relay', 'fixed', (s) => { fixed[+s.port] = true; });

// the records: of each the address and when written; by the write key and by each read key, its name
let records = {}, writers = {}, readers = {};
ctx.foreach('adhoc-relay', 'record', (s) => {
	const name = s.name ?? s['.name'];
	records[name] = null;
	if (s.write)
		writers[s.write] = name;
	for (let k in (type(s.read) == 'array' ? s.read : split(s.read ?? '', ' ')))
		if (k)
			readers[k] = name;
});

// The users of the password and of the read keys, each with the end of its last day, 0 - never: the rules let an expired one
// through no more, and this checks it too - a request on a connection conntrack knows passes the rules unchecked
let passwords = {}, ends = {};
passwords[password] = true;
function ends_on(day) {
	const d = match(day ?? '', /^([0-9]{4})-([0-9]{2})-([0-9]{2})$/);
	return d ? timelocal({ year: +d[1], mon: +d[2], mday: +d[3], hour: 23, min: 59, sec: 59 }) : 0;
}
ctx.foreach('adhoc-relay', 'user', (s) => {
	if (s.of == 'password')
		passwords[s.key] = true;
	else if (substr(s.of ?? '', 0, 1) == '@' && exists(records, substr(s.of, 1)))
		readers[s.key] = substr(s.of, 1);
	else
		return;
	ends[s.key] = ends_on(s.expires);
});
// a key of these is good now: not expired
function good(key) {
	return !ends[key] || time() <= ends[key];
}

// the reports: where this router writes its address. `to` is the line the relay of a fixed address gave for it,
// ✏️<write key>[👀<read key>]👉<host>:<port> - or ! ? > for the signs
let reports = [];
ctx.foreach('adhoc-relay', 'report', (s) => {
	const m = match(plain(s.to), /^!([A-Za-z0-9]{16})(\?[A-Za-z0-9]{16})?>([^ :@=,!?>]+):([0-9]+)$/);
	if (!m) {
		warn(`adhoc-relay: the report to '${s.to}': not ✏️<write key>👀<read key>👉<address>:<port>\n`);
		return;
	}
	push(reports, { key: m[1], host: m[3], at: +m[4], write: m[1],
		sock: null, local: null, tried: 0, sent: 0, answered: 0, seen: null });
});

// a socket of the port of requests, at `address`; null when it cannot be bound. SO_REUSEADDR: the one of all the addresses and
// those of single ones share the port
function at(address) {
	const s = socket.create(socket.AF_INET, socket.SOCK_DGRAM);
	if (s?.setopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, true) && s.bind({ address, port: first }))
		return s;
	s?.close();
	return null;
}

// An answer goes from the address its request came to: the kernel picks the address by the way back otherwise - a server in
// the LAN of the router, asking at its public address, would get the answer from its LAN address, and take none. The socket of
// all the addresses tells the address of each request it gets ( IP_PKTINFO ); the answer goes by a socket bound to that address,
// made at its first request, and the kernel brings the next requests to that address there: each socket answers from itself
const any = at('0.0.0.0');
if (!any) {
	warn(`adhoc-relay: the port ${first}: ${socket.error()}\n`);
	exit(1);
}
any.setopt(socket.IPPROTO_IP, socket.IP_PKTINFO, true);
// the sockets of single addresses: [ socket, address ]
let single = [];

// the address a request came to, of its struct in_pktinfo: ipi_addr, its last 4 bytes
function asked(ancillary) {
	for (let c in ancillary ?? [])
		if (c.level == socket.IPPROTO_IP && c.type == socket.IP_PKTINFO && type(c.data) == 'string' && length(c.data) >= 12)
			return join('.', map(split(substr(c.data, 8, 4), ''), (b) => ord(b)));
	return null;
}

// the socket to answer by, from `address`: made when there is none yet; the socket of all the addresses when it cannot be bound
function by(address) {
	for (let s in single)
		if (s[1] == address)
			return s[0];
	const s = address ? at(address) : null;
	if (!s)
		return any;
	push(single, [ s, address ]);
	return s;
}
srand(time());

// the 4 bytes of an IPv4 address
function bytes4(address) {
	return join('', map(split(address, '.'), (b) => chr(+b)));
}

// a file of /tmp/adhoc-relay, whole: written beside, then put in place, so the page never reads half of it
function save(name, text) {
	mkdir(STATE);
	writefile(`${STATE}/${name}.new`, text);
	rename(`${STATE}/${name}.new`, `${STATE}/${name}`);
}

// the records as the page reads them: "<name> <address> <when written>"
function saveRecords() {
	let text = '';
	for (let name, r in records)
		if (r)
			text += `${name} ${r.address} ${r.when}\n`;
	save('records', text);
}

// the reports as the page reads them: "<host>:<port> <when sent> <when answered, 0 never> <address seen, or ->"
function saveReports() {
	let text = '';
	for (let r in reports)
		text += `${r.host}:${r.at} ${r.sent} ${r.answered} ${r.seen ?? '-'}\n`;
	save('reports', text);
}

// the records kept by the `give` before this one: a change of the settings starts it again, the records live on
for (let line in split(readfile(`${STATE}/records`) ?? '', '\n')) {
	const w = split(line, ' ');
	if (length(w) == 3 && exists(records, w[0]))
		records[w[0]] = { address: w[1], when: +w[2] };
}

// the ports given, by the id they are given to - 16 hex digits, without the zeros in front, as nft shows it: what this `give`
// gave, and what the kernel held at its start. Each is checked in the kernel when its id asks again: a port its side stopped knocking
// at is given to others in time. So a request lists no set: an id never seen gets a port at once
let givenTo = {};
function learn() {
	givenTo = {};
	const p = popen('nft list set ip adhoc_relay owned 2>/dev/null', 'r');
	const all = p?.read('all') ?? '';
	p?.close();
	for (let m in match(all, /([0-9]+) \. 0x([0-9a-f]+)/g))
		givenTo[replace(m[2], /^0+/, '')] = +m[1];
}
learn();

// the port of meeting the id holds, 16 hex digits, as the kernel has it; null - none
function held(id) {
	const want = replace(id, /^0+/, ''), port = givenTo[want];
	if (port != null && system(`nft get element ip adhoc_relay owned '{ ${port} . 0x${id} }' >/dev/null 2>&1`) == 0)
		return port;
	delete givenTo[want];
	return null;
}

// a port of meeting nobody holds, given to `id`, 16 hex digits; null when 16 picks found none free. The ids of the sides that
// never came back are forgotten when there are more of them than ports: the kernel is asked again then
function give(id) {
	for (let i = 0; i < 16; i++) {
		const port = first + 1 + rand() % (last - first);
		if (fixed[port])
			continue;
		if (system([ 'nft', `create element ip adhoc_relay given { ${port} }; add element ip adhoc_relay owned { ${port} . 0x${id} }` ]) == 0) {
			if (length(givenTo) > last - first)
				learn();
			givenTo[replace(id, /^0+/, '')] = port;
			return port;
		}
	}
	return null;
}

// the answer to a Binding Request of STUN, RFC 8489: a Binding Success Response with the address and the port the request came
// from, XOR-MAPPED-ADDRESS - 32 bytes
function stun(data, from) {
	const p = from.port ^ 0x2112, a = split(from.address, '.');
	return '\x01\x01\x00\x0c' + substr(data, 4, 16) + '\x00\x20\x00\x08\x00\x01' + chr(p >> 8, p & 255) +
		chr(+a[0] ^ 0x21, +a[1] ^ 0x12, +a[2] ^ 0xa4, +a[3] ^ 0x42);
}

// a request that came by `s`, to `address`: answered from there
function request(got, s) {
	// on a connection conntrack knows already the rules check no key: it is checked here
	const data = got?.data, from = got?.address;
	let answer = null;
	if (length(data) == 20 && substr(data, 0, 8) === '\x00\x01\x00\x00\x21\x12\xa4\x42') {
		answer = stun(data, from);
	} else if (length(data) == 24 && passwords[substr(data, 0, 16)] && good(substr(data, 0, 16))) {
		// a port of meeting
		const id = join('', map(split(substr(data, 16), ''), (b) => sprintf('%02x', ord(b))));
		const port = held(id) ?? give(id);
		if (port != null)
			answer = chr(port >> 8, port & 255);
	} else if (length(data) == 16 && exists(writers, data)) {
		// a write: the record takes the address it came from
		records[writers[data]] = { address: from.address, when: time() };
		saveRecords();
		answer = bytes4(from.address);
	} else if (length(data) == 16 && exists(readers, data) && good(data)) {
		// a read: the address and the minutes since the last write - none while the record has none
		const r = records[readers[data]];
		const minutes = int((time() - r?.when) / 60);
		if (r)
			answer = bytes4(r.address) + chr(minutes > 255 ? 255 : minutes);
	}
	if (answer != null)
		(s === any ? by(asked(got.ancillary)) : s).send(answer, 0, from);
}

// the address this router writes from to the relay of report `r`, as the kernel picks it now: a socket connected there,
// no packet sent; null - no way there now
function local(r) {
	const s = socket.create(socket.AF_INET, socket.SOCK_DGRAM);
	const ok = r.addr && s?.connect(r.addr);
	const here = ok ? s.sockname()?.address : null;
	s?.close();
	return here;
}

// report `r` written: its name looked up anew when `look`, a new socket when the way there changed - another address of this
// router, or of that relay
function write(r, look) {
	r.tried = time();
	if (look || !r.addr) {
		const found = socket.addrinfo(r.host, `${r.at}`, { family: socket.AF_INET, socktype: socket.SOCK_DGRAM });
		if (found?.[0])
			r.addr = found[0].addr;
	}
	const here = local(r);
	if (!here)
		return;
	if (!r.sock || here != r.local || r.addr.address != r.to) {
		r.sock?.close();
		r.sock = socket.create(socket.AF_INET, socket.SOCK_DGRAM);
		if (!r.sock?.connect(r.addr)) {
			r.sock?.close();
			r.sock = null;
			return;
		}
		r.local = here;
		r.to = r.addr.address;
	}
	r.sock.send(r.write);
	r.sent = time();
	saveReports();
}

for (let r in reports)
	write(r, true);
saveReports();
saveRecords();

// what the meetings of the users of ports carried is kept each hour - `rules save` writes it only when it changed: a router
// that loses its power loses an hour of it at most. No users of ports: never woken for it
let with_users = false, kept = time();
ctx.foreach('adhoc-relay', 'user', (s) => { if (s.of == 'password' || match(s.of ?? '', /^[0-9]+$/)) with_users = true; });

for (;;) {
	let watched = [ [ any, socket.POLLIN ] ];
	for (let s in single)
		push(watched, [ s[0], socket.POLLIN ]);
	for (let r in reports)
		if (r.sock)
			push(watched, [ r.sock, socket.POLLIN ]);
	// woken each 2 s at most when there are reports: has the address changed, is one due
	socket.poll(length(reports) ? 2000 : with_users ? 3600000 : -1, ...watched);
	if (with_users && time() - kept >= 3600) {
		kept = time();
		system('/usr/libexec/adhoc-relay/rules save');
	}
	// every socket, what it has: without waiting
	for (let got; (got = any.recvmsg(64, 64, socket.MSG_DONTWAIT));)
		request(got, any);
	for (let s in single)
		for (let got; (got = s[0].recvmsg(64, 0, socket.MSG_DONTWAIT));)
			request(got, s[0]);
	const now = time();
	for (let r in reports) {
		// the answer: the address this router wrote from, as that relay saw it
		for (let got; r.sock && (got = r.sock.recv(16, socket.MSG_DONTWAIT));)
			if (length(got) == 4) {
				r.answered = now;
				r.seen = join('.', map(split(got, ''), (b) => ord(b)));
				saveReports();
			}
		// each 60 s, its name looked up again; at once when this router writes from another address now - not while it has
		// no way there at all: the name is not looked up each 2 s then
		if (now - r.tried >= 60)
			write(r, true);
		else if (r.local) {
			const here = local(r);
			if (here && here != r.local)
				write(r, false);
		}
	}
}
