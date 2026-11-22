#!/usr/bin/ucode
// AdHoc Relay: binds a port of meeting to a server. No key travels: a key is known by its id - the first 8 bytes of SHA-256 of
// "AdHoc Relay id" and the key -, and what is said with it is 8 bytes of HMAC-SHA256 made with the key.
//
// A bind, to the first port of the range, 24 bytes: the id of the key, the id of the server - 8 random bytes of its own - and
// HMAC of "bind", that id and the address this router sees the server at, 4 bytes. Made for that address: the answer is a port
// of the others, 2 bytes, high first - one nobody holds, or the fixed port of the key -, the address, 4 bytes, the times of the
// server, 3 bytes - how often it knocks, seconds, how long a try of its dialing is, seconds, how often it binds again, minutes
// - and HMAC of "bound", the id, that port, that address and the times, 8 bytes; made for another: the address, and HMAC of
// "seen", the id and the address, and the server binds again with it. An answer is signed by the key of its request: nobody
// else answers in the name of this router. The key of the knocks of the port - 16 bytes, HMAC of "knock", the id, the port and
// the address - goes into the rules with the port and the address, for two times `rebind`: the kernel opens the port at knocks
// with it from that address, and no program wakes for a knock. A server binds anew each `rebind` minutes. The rules let only
// the id of a key through, a few a second from an address; the port is taken in the kernel - `nft create`, which fails when the
// port is taken already - so no two servers get one port, whatever else adds there. A server that binds again - its answer lost,
// or behind another address now - gets its port again.
//
// The records, at the same port, 16 bytes each. A relay of a changing address writes: the id of its write key and HMAC of "write"
// and the address it is seen at - the record keeps the address the write came from when the two agree, and the answer is that
// address, 4 bytes, either way. A read: the id of a read key and 8 random bytes; the answer is the address, the minutes since the
// last write, and 8 bytes of HMAC of "read", those random bytes, the address and the minutes - 13 bytes: the server takes the
// answer of nobody else. And the reports: this router writes its own address into the records of other relays, every 60 s, and
// at once when its address changes. What the records and the reports hold is in /tmp/adhoc-relay, for the page. The settings
// are those of /etc/config/adhoc-relay, the keys that bind as `rules` wrote them; procd starts this again when they change.
//
// And STUN, at the same port: a Binding Request gets the address and the port it came from - a side and a client that meet
// directly learn there where the internet sees them. The calls themselves pass the kernel only, never this.

import * as socket from 'socket';
import { cursor } from 'uci';
import { rand, srand } from 'math';
import { popen, open, readfile, writefile, rename, mkdir } from 'fs';
import * as digest from 'digest';

// the settings of the last load of the rules that went well, where the service keeps their copy - its argument; started by
// hand, with none: the settings as they are
const ctx = ARGV[0] ? cursor(ARGV[0], `${ARGV[0]}/delta`, '') : cursor();
const main = ctx.get_all('adhoc-relay', 'main') ?? {};
const first = +(main.first ?? 40000), last = +(main.last ?? 49999);
// The times of the servers, told in the answer to a bind: how often a server knocks, seconds; how long a try of its dialing is,
// seconds - the rules know where it waits by it -; how often it binds again, minutes - the key of its knocks lives two times
// that. Each a byte
const knockEvery = +(main.knock ?? 20), dialFor = +(main.dial ?? 31), rebind = +(main.rebind ?? 30);
const times = chr(knockEvery, dialFor, rebind);
const STATE = '/tmp/adhoc-relay';

// the id of a key, 16 hex digits - 8 bytes: what a side names its key by
function kid(key) {
	return substr(digest.sha256('AdHoc Relay id' + key), 0, 16);
}

// HMAC-SHA256 of the words with a key, 32 bytes: the module has the hash alone. The key padded, inner and outer, made once for
// each key - a loop over its 64 bytes is some 6 ms of a router, the two hashes after it a tenth of a millisecond, and a bind
// says three things with its key
let pads = {};
function hmac(key, words) {
	let p = pads[key];
	if (!p) {
		let inner = '', outer = '';
		for (let i = 0; i < 64; i++) {
			const k = i < length(key) ? ord(key, i) : 0;
			inner += chr(k ^ 0x36);
			outer += chr(k ^ 0x5c);
		}
		p = pads[key] = [ inner, outer ];
	}
	return hexdec(digest.sha256(p[1] + hexdec(digest.sha256(p[0] + words))));
}

// what a key says of some words: the first bytes of it, 8 unless asked
function said(words, key, n) {
	return substr(hmac(key, words), 0, n ?? 8);
}

// a line with the signs of the keyboard: ✏️ !, 👀 ?, 👉 > - what makes an emoji coloured, or the colour of skin, left out
function plain(line) {
	line = line ?? '';
	for (let s in [ '\xef\xb8\x8f', '\xf0\x9f\x8f\xbb', '\xf0\x9f\x8f\xbc', '\xf0\x9f\x8f\xbd', '\xf0\x9f\x8f\xbe', '\xf0\x9f\x8f\xbf' ])
		line = replace(line, s, '');
	return trim(replace(replace(replace(line, '\xe2\x9c\x8f', '!'), '\xf0\x9f\x91\x80', '?'), '\xf0\x9f\x91\x89', '>'));
}

// The keys that bind a port, as `rules` loaded them: by the id of each, the key, the mark its sides are noted with, its fixed
// port - 0: any -, the end of its last day - 0: never. The fixed ports: never given at random
let binder = {}, fixed = {};
for (let line in split(readfile(`${STATE}/binders`) ?? '', '\n')) {
	const w = split(line, ' ');
	if (length(w) != 5 || !match(w[0], /^[0-9a-f]{16}$/))
		continue;
	binder[w[0]] = { key: w[4], mark: w[1], port: +w[2], ends: +w[3] };
	if (+w[2])
		fixed[+w[2]] = true;
}

function ends_on(day) {
	const d = match(day ?? '', /^([0-9]{4})-([0-9]{2})-([0-9]{2})$/);
	return d ? timelocal({ year: +d[1], mon: +d[2], mday: +d[3], hour: 23, min: 59, sec: 59 }) : 0;
}

// the records: of each the address and when written; by the id of the write key and of each read key, the key and the name
let records = {}, writers = {}, readers = {};
ctx.foreach('adhoc-relay', 'record', (s) => {
	const name = s.name ?? s['.name'];
	records[name] = null;
	if (s.write)
		writers[kid(s.write)] = { key: s.write, name };
	for (let k in (type(s.read) == 'array' ? s.read : split(s.read ?? '', ' ')))
		if (k)
			readers[kid(k)] = { key: k, name, ends: 0 };
});

// the users of the read keys, each with the end of its last day, 0 - never: the rules let an expired one through no more, and
// this checks it too
ctx.foreach('adhoc-relay', 'user', (s) => {
	if (s.key && substr(s.of ?? '', 0, 1) == '@' && exists(records, substr(s.of, 1)))
		readers[kid(s.key)] = { key: s.key, name: substr(s.of, 1), ends: ends_on(s.expires) };
});
// a key of these is good now: not expired
function good(key) {
	return !key.ends || time() <= key.ends;
}

// the reports: where this router writes its address. `to` is the line the relay of a fixed address gave for it,
// ✏️<write key>[👀<read key>]👉<host>:<port> - or ! ? > for the signs
let reports = [];
ctx.foreach('adhoc-relay', 'report', (s) => {
	// a name or an address, of what names are made of - as on a Linux computer, where the settings are the text of a shell too
	const m = match(plain(s.to), /^!([A-Za-z0-9]{16})(\?[A-Za-z0-9]{16})?>([A-Za-z0-9][A-Za-z0-9._-]*):([0-9]{1,5})$/);
	if (!m) {
		warn(`adhoc-relay: the report to '${s.to}': not ✏️<write key>👀<read key>👉<address>:<port>\n`);
		return;
	}
	// `as`: the address that relay saw this router at last, 4 bytes - a write is made for it; none yet: 0.0.0.0
	push(reports, { key: m[1], host: m[3], at: +m[4], write: m[1], as: '\x00\x00\x00\x00', again: 0,
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
	// a router whose address changes leaves a socket at each address it had: past 16 they all go, those of now come again
	if (address && length(single) >= 16) {
		for (let s in single)
			s[0].close();
		single = [];
	}
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

// The sides bound, by their ids - 16 hex digits: the port of each, the id of its key, the address it bound from, the key of its
// knocks, its mark, and when that key ends in each of the 4 maps of the rules - `at`; `until` is the last of them.
// The rules keep the keys of the knocks in 4 maps, one for each `rebind` minutes in turn - `slot`: a side bound again is put into
// the map of now, its time full, and what it has in the maps of before ends by itself. An element there is gets no more time
// but by being taken out first, and `nft delete` reads every rule of the router for that - ten times the work of an `add`; a
// side binds again each `rebind` minutes, and that is most of what `give` does. A map is used again four times that later:
// what it held, for two times that, is long gone.
// In /tmp/adhoc-relay/bound a line for each time a side was bound - "<id> <port> <id of the key> <address> <key of the knocks>
// <ends> <mark> <slot>" -, added at its end: not the whole file written at each bind. Written anew, short, at a start and when
// it grew long. A change of the settings starts `give` again, the sides bound live on by it.
let bound = {}, owner = {}, journal = null, noted = 0;
function slot(now) {
	return int(now / (rebind * 60)) % 4;
}
function saveBound() {
	journal?.close();
	const now = time();
	let lines = [];
	for (let id, b in bound)
		for (let s = 0; s < 4; s++)
			if (b.at[s] > now)
				push(lines, `${id} ${b.port} ${b.kid} ${b.addr} ${b.knock} ${b.at[s]} ${b.mark} ${s}\n`);
	save('bound', join('', lines));
	noted = 0;
	journal = open(`${STATE}/bound`, 'a');
}
// the side was bound a moment ago: its line
function noteBound(id) {
	if (!journal || ++noted > 1000 + 2 * length(bound))
		return saveBound();
	const b = bound[id];
	journal.write(`${id} ${b.port} ${b.kid} ${b.addr} ${b.knock} ${b.at[b.slot]} ${b.mark} ${b.slot}\n`);
	journal.flush();
}

// what the map of a slot holds of a side: its key of the knocks with the port and the address, and without the address
function held(b, s) {
	return [ `bound${s} { ${b.port} . ${b.addr} . 0x${b.knock}`, `bound_any${s} { ${b.port} . 0x${b.knock}` ];
}

// The lock of the ports given: `rules load` takes it while it reads what the table holds and puts the new table in its place - a
// port given in that moment would be of neither, its server answered and the port forgotten. Taken here, on the file itself:
// no `flock` started for each command - a process less at each bind, some 6 ms of a router
mkdir(STATE);
const lock = open(`${STATE}/lock`, 'a');

// commands of nft, as one: all of them, or none. What fails is no error here - a port taken, an element gone -, and no line of the log
function nft(commands) {
	lock?.lock('x');
	const ok = system(`nft '${join('; ', commands)}' 2>/dev/null`) == 0;
	lock?.lock('u');
	return ok;
}

// The port is of this side now: whoever held it before - its knocks long ended - holds it no more. With `rules`: its keys of
// knocks that live still are taken out of the rules too - a knock of it would open a port of another. Not a fixed port: every
// server of its key binds it.
function own(id, port, rules) {
	if (fixed[port])
		return;
	const o = owner[port], was = o != null && o != id ? bound[o] : null;
	if (was && was.port == port) {
		if (rules) {
			const now = time();
			for (let s = 0; s < 4; s++)
				if (was.at[s] > now) {
					const h = held(was, s);
					nft([ `delete element ip adhoc_relay ${h[0]} }`, `delete element ip adhoc_relay ${h[1]} }` ]);
				}
		}
		delete bound[o];
	}
	owner[port] = id;
}

// Those of before: one whose key is no more - taken away, changed, its day over - or binds another port now is taken out of the
// rules at once; one whose key has another mark now - its user got a limit, or the direct path only - is put there anew with it.
// One command for them all
{
	const now = time();
	for (let line in split(readfile(`${STATE}/bound`) ?? '', '\n')) {
		const w = split(line, ' ');
		if (length(w) < 7 || +w[5] <= now)
			continue;
		let b = bound[w[0]];
		// another port, address or key of knocks than its lines before: bound anew since
		if (!b || b.port != +w[1] || b.addr != w[3] || b.knock != w[4])
			b = bound[w[0]] = { port: +w[1], kid: w[2], addr: w[3], knock: w[4], mark: w[6], until: 0, at: [ 0, 0, 0, 0 ] };
		// a line with no slot is of a `give` before the maps: nothing of it is in the rules, the side keeps its port
		if (length(w) == 8 && match(w[7], /^[0-3]$/))
			b.at[+w[7]] = +w[5];
		if (+w[5] > b.until)
			b.until = +w[5];
		b.mark = w[6];
		own(w[0], b.port);
	}
	let commands = [];
	for (let id in keys(bound)) {
		const b = bound[id], key = binder[b.kid];
		if (!key || !good(key) || (key.port && key.port != b.port)) {
			for (let s = 0; s < 4; s++)
				if (b.at[s] > now) {
					const h = held(b, s);
					push(commands, `delete element ip adhoc_relay ${h[0]} }`, `delete element ip adhoc_relay ${h[1]} }`);
				}
			if (owner[b.port] == id)
				delete owner[b.port];
			delete bound[id];
			continue;
		}
		if (key.mark != b.mark) {
			for (let s = 0; s < 4; s++)
				if (b.at[s] > now) {
					const h = held(b, s);
					push(commands, `delete element ip adhoc_relay ${h[0]} }`, `add element ip adhoc_relay ${h[0]} timeout ${b.at[s] - now}s : ${key.mark} }`);
				}
			b.mark = key.mark;
		}
	}
	// one of them gone from the rules a moment ago fails the command whole: each by itself then
	if (length(commands) && !nft(commands))
		for (let c in commands)
			nft([ c ]);
	saveBound();
}

// The side is bound: the key of its knocks in the map of now, with its port and the address, for two times `rebind` - or till
// the last day of its key ends. `how`: 'create' - the port is taken in the kernel, when nobody holds it: `nft create` fails when
// it is taken; 'add' - the port is its own already. Its element of this map, there already - bound twice in one `rebind` -,
// keeps the time it has: no less than one `rebind` more than the side needs till it binds again
function bindSide(id, b, key, how) {
	const now = time();
	let left = rebind * 120;
	if (key.ends && key.ends - now < left)
		left = key.ends - now;
	if (left < 1)
		return false;
	const s = slot(now), h = held(b, s);
	if (!nft([ `${how} element ip adhoc_relay given { ${b.port} }`, `add element ip adhoc_relay ${h[0]} timeout ${left}s : ${key.mark} }`,
		`add element ip adhoc_relay ${h[1]} timeout ${left}s }` ]))
		return false;
	const was = bound[id];
	// the same side as before: what it has in the other maps lives on to its end
	let at = was && was.knock == b.knock && was.port == b.port && was.addr == b.addr ? was.at : [ 0, 0, 0, 0 ];
	if (at[s] <= now)
		at[s] = now + left;
	bound[id] = { port: b.port, kid: b.kid, addr: b.addr, knock: b.knock, until: max(...at), mark: key.mark, at, slot: s };
	return true;
}

// A side that binds again and changes nothing - the same port, address, key of the knocks and user, its key alive in the rules
// still -: answered at once, and its key goes into the map of now later, with the others - one nft for all that came in
// `LATER` s. Each start of nft is some 25 ms of a router: with thousands of servers binding again every `rebind` minutes, one
// for each was most of what `give` did. The side loses nothing meanwhile: its key lives on where it is, half its time at least.
// By id: a side that binds twice meanwhile is added once. In the map of now already - bound twice in one `rebind` -: nothing
// to add, an element there keeps the time it has
const LATER = 10;
let later = {}, laterSince = 0;
// The keys put off, into the rules now: all in one nft. One that fails - an element gone, the rules loaded anew meanwhile -:
// each side alone then
function renewNow() {
	const due = later;
	later = {};
	const commands = (b, l) => {
		const h = held(b, l.s);
		return [ `add element ip adhoc_relay given { ${b.port} }`, `add element ip adhoc_relay ${h[0]} timeout ${l.left}s : ${l.mark} }`,
			`add element ip adhoc_relay ${h[1]} timeout ${l.left}s }` ];
	};
	let all = [];
	for (let id, l in due)
		if (bound[id])
			push(all, ...commands(bound[id], l));
	const together = length(all) && nft(all);
	for (let id, l in due) {
		const b = bound[id];
		if (!b || !(together || nft(commands(b, l))))
			continue;
		if (b.at[l.s] < l.until)
			b.at[l.s] = l.until;
		b.until = max(...b.at);
		b.slot = l.s;
		noteBound(id);
	}
}

function renewLater(id, b, key) {
	const now = time(), s = slot(now);
	let left = rebind * 120;
	if (key.ends && key.ends - now < left)
		left = key.ends - now;
	if (b.at[s] > now || left < 1)
		return;
	if (!length(later))
		laterSince = now;
	later[id] = { s, left, until: now + left, mark: key.mark };
	if (length(later) >= 150)
		renewNow();
}

// A port of meeting nobody holds, bound to the side; null - there is none. A few picks at random first: with most of the range
// free the first is free, and nobody tells the next port from the last. None of them free - the range is nearly full -: the
// ports given are read from the kernel once - it alone knows them, they end there by themselves -, and a free one is taken of
// those left, from a place picked at random: a port there is is found
function give(id, b, key, make) {
	const range = last - first;
	// taken: whoever held this port before, its knocks long ended, holds it no more
	const tryPort = (pick) => {
		b.port = pick;
		b.knock = make(pick);
		if (!bindSide(id, b, key, 'create'))
			return false;
		own(id, pick, true);
		return true;
	};
	for (let i = 0; i < 8; i++) {
		const pick = first + 1 + rand() % range;
		if (!fixed[pick] && tryPort(pick))
			return pick;
	}
	const p = popen('nft list set ip adhoc_relay given 2>/dev/null', 'r');
	const all = p?.read('all') ?? '';
	p?.close();
	let taken = {};
	for (let m in match(all, /([0-9]+) (timeout [^ ]+ )?expires/g))
		taken[m[1]] = true;
	const from = rand() % range;
	// one that was free a moment ago may be taken by now - by another `give`, by a load: a few tries, no more
	for (let i = 0, tried = 0; i < range && tried < 8; i++) {
		const pick = first + 1 + (from + i) % range;
		if (fixed[pick] || taken[`${pick}`])
			continue;
		tried++;
		if (tryPort(pick))
			return pick;
	}
	return null;
}

// a bind made right, of a side at `address` - its 4 bytes: the port bound to it, null - none
function bind(k, kidHex, side, address, text) {
	const id = hexenc(side);
	const make = (port) => hexenc(said('knock' + side + chr(port >> 8, port & 255) + address, k.key, 16));
	let b = { kid: kidHex, addr: text };
	const was = bound[id];
	// the port: the fixed one of the key; the one the side holds - bound again, from this address or another; a new one
	let port = k.port || (was && was.kid == kidHex && !fixed[was.port] ? was.port : 0);
	// bound again, nothing changed - the key of its knocks is of the id, the port, the address and the key, the same all: its key
	// into the rules later, with others
	if (port && was && was.port == port && was.addr == text && was.mark == k.mark && was.until > time()) {
		renewLater(id, was, k);
		return port;
	}
	if (port) {
		b.port = port;
		b.knock = make(port);
		// its own port, or free since it stopped knocking: its again. Given to another meanwhile: a new one
		if (!bindSide(id, b, k, k.port || (was && was.until > time()) ? 'add' : 'create'))
			port = 0;
	}
	if (!port && !k.port)
		port = give(id, b, k, make);
	if (!port)
		return null;
	// the ids of the sides that never came back are forgotten: their keys of knocks ended in the rules by themselves
	if (length(bound) > 2 * (last - first)) {
		const now = time();
		for (let other in keys(bound))
			if (bound[other].until <= now)
				delete bound[other];
	}
	noteBound(id);
	return port;
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
	const data = got?.data, from = got?.address;
	let answer = null;
	if (length(data) == 20 && substr(data, 0, 8) === '\x00\x01\x00\x00\x21\x12\xa4\x42') {
		answer = stun(data, from);
	} else if (length(data) == 24) {
		// a bind: the id of a key that binds, the id of the side, and what the key says of "bind", that id and the address
		const kidHex = hexenc(substr(data, 0, 8)), k = binder[kidHex];
		if (k && good(k)) {
			const side = substr(data, 8, 8), address = bytes4(from.address);
			if (substr(data, 16) !== said('bind' + side + address, k.key)) {
				// made for another address - the side does not know yet where it is seen, or its NAT changed it: told where
				answer = address + said('seen' + side + address, k.key);
			} else {
				const port = bind(k, kidHex, side, address, from.address);
				if (port) {
					const told = chr(port >> 8, port & 255) + address + times;
					answer = told + said('bound' + side + told, k.key);
				}
			}
		}
	} else if (length(data) == 16) {
		const by8 = hexenc(substr(data, 0, 8)), address = bytes4(from.address);
		if (writers[by8]) {
			// a write: the record takes the address it came from, when it was made for that address; the answer is the address,
			// and what the write key says of "seen" and it
			const w = writers[by8];
			if (substr(data, 8) === said('write' + address, w.key)) {
				records[w.name] = { address: from.address, when: time() };
				saveRecords();
			}
			answer = address + said('seen' + address, w.key);
		} else if (readers[by8] && good(readers[by8])) {
			// a read: the address and the minutes since the last write - none while the record has none -, and what the read
			// key says of them and of the 8 bytes that came
			const r = readers[by8], rec = records[r.name];
			if (rec) {
				const minutes = int((time() - rec.when) / 60);
				const told = bytes4(rec.address) + chr(minutes > 255 ? 255 : minutes);
				answer = told + said('read' + substr(data, 8) + told, r.key);
			}
		}
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
	// the id of the write key, and what the key says of "write" and the address this router is seen at there
	r.sock.send(hexdec(kid(r.write)) + said('write' + r.as, r.write));
	r.sent = time();
	saveReports();
}

for (let r in reports)
	write(r, true);
saveReports();
saveRecords();

// what the meetings of the users that have a limit carried is kept each hour - `rules save` writes it only when it changed: a
// router that loses its power loses an hour of it at most. Nothing is counted of the others: no user with a limit, never
// woken for it
let with_users = false, kept = time();
ctx.foreach('adhoc-relay', 'user', (s) => {
	if ((s.of == 'password' || match(s.of ?? '', /^[0-9]+$/)) && s.direct != '1' && +(s.limit ?? 0) > 0)
		with_users = true;
});

for (;;) {
	let watched = [ [ any, socket.POLLIN ] ];
	for (let s in single)
		push(watched, [ s[0], socket.POLLIN ]);
	for (let r in reports)
		if (r.sock)
			push(watched, [ r.sock, socket.POLLIN ]);
	// woken each 2 s at most when there are reports: has the address changed, is one due; and when the keys put off are due
	let wait = length(reports) ? 2000 : with_users ? 3600000 : -1;
	if (length(later)) {
		const due = max(0, (laterSince + LATER - time()) * 1000);
		wait = wait < 0 || due < wait ? due : wait;
	}
	socket.poll(wait, ...watched);
	if (length(later) && time() - laterSince >= LATER)
		renewNow();
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
		// the answer: the address this router wrote from, as that relay saw it - signed by the write key, or it is of nobody
		for (let got; r.sock && (got = r.sock.recv(16, socket.MSG_DONTWAIT));)
			if (length(got) == 12 && substr(got, 4) === said('seen' + substr(got, 0, 4), r.write)) {
				got = substr(got, 0, 4);
				r.answered = now;
				r.seen = join('.', map(split(got, ''), (b) => ord(b)));
				saveReports();
				// seen at another address than the write was made for: written again, for that one - once in 2 s at most
				if (got !== r.as && now - r.again >= 2) {
					r.as = got;
					r.again = now;
					r.sock.send(hexdec(kid(r.write)) + said('write' + r.as, r.write));
				}
			}
		// each 60 s; its name looked up again only when the write before got no answer - that relay may have moved, and a
		// look-up that finds no DNS holds the requests for a port meanwhile. At once when this router writes from another
		// address now - not while it has no way there at all: the name is not looked up each 2 s then
		if (now - r.tried >= 60)
			write(r, r.answered < r.sent);
		else if (r.local) {
			const here = local(r);
			if (here && here != r.local)
				write(r, false);
		}
	}
}
