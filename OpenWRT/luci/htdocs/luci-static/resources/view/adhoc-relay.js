'use strict';
'require view';
'require form';
'require rpc';
'require poll';
'require ui';
'require uci';
'require dom';

// The page of AdHoc Relay. On top, one card: whether the router serves, its public IP and whether it changes, its ports, what goes
// on now; until it serves, the steps there. Then tabs: Ports - the ports given and the fixed ports, each line copied, never shown,
// what each does now in the tooltip of its number; under them the addresses blocked, and the last 10 minutes folded; Users;
// Changing IP - On my public IP change, notify the following relays, and Track the public IP of other relays; Settings, the removal too. Names and values on the
// page, what each does in its tooltip. Save & Apply is shown on Settings alone: the rest saves and applies at once.
//
// The flow of a changing IP, from one router to another: on the router of a fixed IP, Track the public IP of other relays, Add - its line
// is copied; on the router whose IP changes, On my public IP change, notify the following relays, the line pasted, Add. Each Add saves and applies at once.

var callAddress = rpc.declare({ object: 'adhoc-relay', method: 'address' });
// what the router does now; `meetings` and `tries` - whether to make those parts: the costly ones, asked for only while shown
var callStatus = rpc.declare({ object: 'adhoc-relay', method: 'status', params: [ 'meetings', 'tries' ] });
var callUninstall = rpc.declare({ object: 'adhoc-relay', method: 'uninstall' });
// an address blocked let in again; `port` - where it was blocked for guessing, 0 - blocked at every port
var callUnblock = rpc.declare({ object: 'adhoc-relay', method: 'unblock', params: [ 'address', 'port' ] });

// the colours of the states: on the dark and the light themes alike
var GOOD = '#2e9e5b', WARN = '#e8a33a', BAD = '#d9534f', INFO = '#4a9fd8';

// asks, then takes AdHoc Relay off the router; the page goes to the overview of the router once it is gone
function uninstall() {
	ui.showModal(_('Uninstall AdHoc Relay'), [
		E('p', _('This removes the rules, the service, this page and all the settings, the password and the keys too. Connections through this router end now.')),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
			E('button', { 'class': 'btn cbi-button-negative', 'click': function() {
				poll.stop();
				ui.showModal(_('Uninstall AdHoc Relay'), [ E('p', { 'class': 'spinning' }, _('Removing…')) ]);
				return callUninstall().then(function(r) {
					if (!r || !r.started)
						throw new Error(_('the uninstall script is missing on the router'));
					// the browser keeps the menu it loaded at the login: forgotten, so that this page is gone from it at once
					window.setTimeout(function() {
						if (ui.menu && ui.menu.flushCache) ui.menu.flushCache();
						try { window.sessionStorage.removeItem('menu'); } catch (e) { }
						window.location = L.url('admin/status/overview');
					}, 5000);
				}).catch(function(e) {
					ui.hideModal();
					ui.addNotification(null, E('p', _('Not uninstalled: ') + e.message), 'error');
					poll.start();
				});
			} }, _('Uninstall'))
		])
	]);
}

// 16 letters and digits, those that are not mistaken for one another when read aloud or typed
function newPassword() {
	var abc = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789', bytes = new Uint8Array(24), out = '';
	// each sign as likely as another: a byte past the last whole run of the signs is thrown away, not folded onto the first ones
	var whole = 256 - 256 % abc.length;
	while (out.length < 16) {
		window.crypto.getRandomValues(bytes);
		for (var i = 0; i < bytes.length && out.length < 16; i++)
			if (bytes[i] < whole) out += abc.charAt(bytes[i] % abc.length);
	}
	return out;
}

// the clipboard of the browser: navigator.clipboard is there on https only, LuCI is mostly http
function copyText(text) {
	if (navigator.clipboard && window.isSecureContext)
		return navigator.clipboard.writeText(text).then(function() { return true; }, function() { return copyBySelection(text); });
	return Promise.resolve(copyBySelection(text));
}

function copyBySelection(text) {
	// read only: a phone opens no keyboard for it; its range set too - select() alone selects nothing on iOS
	var t = E('textarea', { 'readonly': 'readonly', 'style': 'position:fixed; top:0; left:0; opacity:0' });
	t.value = text;
	document.body.appendChild(t);
	t.select();
	try { t.setSelectionRange(0, text.length); } catch (e) {}
	var ok = false;
	try { ok = document.execCommand('copy'); } catch (e) {}
	document.body.removeChild(t);
	return ok;
}

function bytesText(n) {
	if (n == null) return null;
	var units = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0;
	while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
	return (i ? n.toFixed(1) : n) + ' ' + units[i];
}

// seconds in words: 52 s, 9 min 58 s, 3 h 12 min
function spanText(s) {
	if (s == null || isNaN(s)) return '-';
	s = Math.floor(s);
	return s < 60 ? _('%d s').format(s) : s < 3600 ? _('%d min %d s').format(Math.floor(s / 60), s % 60) : _('%d h %d min').format(Math.floor(s / 3600), Math.floor(s % 3600 / 60));
}

function agoText(s) {
	return s == null ? _('never') : _('%s ago').format(spanText(s));
}

// a time as nft writes it, 9m59s or 1h2m3s500ms, in words
function nftSpan(t) {
	var all = 0, unit = { d: 86400, h: 3600, m: 60, s: 1, ms: 0.001 }, m, re = /(\d+)(ms|d|h|m|s)/g;
	if (t == null || !/\d/.test(t)) return t || '-';
	while ((m = re.exec(t)) != null) all += m[1] * unit[m[2]];
	return spanText(all);
}

// what a port held is doing: closed - its server waits for a yes of its person, or met a moment ago - open, or open and dialed
function portState(p) {
	if (p.state == 'dialing')
		return _('Open · the server is waiting for a client, from %s').format(p.dials);
	if (p.state == 'open')
		return _('Open · the server has not dialed in yet');
	return _('Closed · held for its server');
}

// what a try of the last minutes was, in words
var tryWords = {
	'request': _('Asked for a port'),
	'knock': _('Knock by the server of the port'),
	'wrong': _('Wrong password or key'),
	'blocked': _('Ignored: a blocked address'),
	'guessing': _('Ignored: it guessed passwords at this port'),
	'dial-a': _('The server of the port dialed in'),
	'dial': _('Connection from a client, or a stranger'),
	'wrote': _('Reported its IP'),
	'read': _('A server looked up an IP'),
	'call': _('A client called the server, to meet it directly')
};

function first() { return +(uci.get('adhoc-relay', 'main', 'first') || 40000); }
function last() { return +(uci.get('adhoc-relay', 'main', 'last') || 49999); }

// the signs of the lines: 👉, 🌐, 👀, ✏️ - typed as > @ ? !
var ARROW = '👉', GLOBE = '🌐', EYES = '👀', PEN = '✏️';

// a line with the signs of the keyboard: what makes an emoji coloured, or the colour of skin, left out
function plain(t) {
	return String(t || '').replace(/️|\ud83c[\udffb-\udfff]/g, '').split(ARROW).join('>').split(GLOBE).join('@').split(EYES).join('?').split('✏').join('!').trim();
}

// the line a report writes to: ✏️<write key>[👀<read key>]👉<relay>:<its port>, as the page of that relay copies it; null - no
// such line
function parseTo(to) {
	// the relay: a name or an address, of what names are made of - as `give` and the command of a Linux computer take it. Its
	// port as a number: with zeros in front it would not be the one `give` says its answers came from
	var m = /^!([A-Za-z0-9]{16})(?:\?([A-Za-z0-9]{16}))?>([A-Za-z0-9][A-Za-z0-9._-]*):(\d{1,5})$/.exec(plain(to));
	if (!m || +m[4] < 1 || +m[4] > 65535) return null;
	return { write: m[1], read: m[2], host: m[3], port: String(+m[4]) };
}

// the line of a report as it is kept and shown
function toLine(r) {
	return PEN + r.write + (r.read ? EYES + r.read : '') + ARROW + r.host + ':' + r.port;
}

// each key of the settings, the password too, must be different, and each fixed port and each name of a record another: the
// words of the first one twice, or null
function twice() {
	var seen = {}, ports = {}, names = {}, found = null;
	function key(k, what) {
		if (!k || found) return;
		if (seen[k]) found = _('%s and %s have the same key: every key, and the password, must be different.').format(seen[k], what);
		else seen[k] = what;
	}
	key(uci.get('adhoc-relay', 'main', 'password'), _('The password'));
	uci.sections('adhoc-relay', 'fixed').forEach(function(s) {
		if (s.port && ports[s.port] && !found) found = _('Port %s is fixed twice.').format(s.port);
		ports[s.port] = true;
		key(s.key, _('Fixed port %s').format(s.port || '?'));
	});
	uci.sections('adhoc-relay', 'record').forEach(function(s) {
		if (s.name && names[s.name] && !found) found = _('Two routers are named %s.').format(s.name);
		names[s.name] = true;
		key(s.write, _('The write key of %s').format(s.name || '?'));
		L.toArray(s.read).forEach(function(k) { key(k, _('A read key of %s').format(s.name || '?')); });
	});
	uci.sections('adhoc-relay', 'user').forEach(function(s) { key(s.key, _('The user %s').format(s.name || '?')); });
	return found;
}

// the tags of a user, numbers of 0-255
function tagsOf(s) {
	return L.toArray(s.tags).map(Number);
}

// the tags of a user as one number of 8 bytes, a tag each - sorted, the last repeated to fill the 8 -, as two halves of 32 bits:
// JavaScript counts exactly to 53 bits only. A selection compares bytes, nothing else
function packed(tags) {
	var t = tags.filter(function(v, i, a) { return a.indexOf(v) == i; }).sort(function(a, b) { return a - b; });
	if (!t.length) return null;
	var b = [];
	for (var i = 0; i < 8; i++) b.push(t[i < t.length ? i : t.length - 1]);
	return [ ((b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]) >>> 0, ((b[4] << 24) | (b[5] << 16) | (b[6] << 8) | b[7]) >>> 0 ];
}
function hasTag(n, tag) {
	if (!n) return false;
	for (var h = 0; h < 2; h++)
		for (var s = 0; s < 32; s += 8)
			if (((n[h] >>> s) & 255) == tag) return true;
	return false;
}
// a user has each of the tags - or with `any` one of them; no tags wanted: every user
function tagged(s, want, any) {
	if (!want || !want.length) return true;
	var n = packed(tagsOf(s));
	return any ? want.some(function(t) { return hasTag(n, t); }) : want.every(function(t) { return hasTag(n, t); });
}

function table(head) {
	return E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' }, head.map(function(h) { return E('th', { 'class': 'th' }, h); }))
	]);
}

// The rows of a table. A name, an address, a line - whatever the settings or the router say - is text, never HTML: a word alone
// in a cell would be taken for HTML, so it goes there as a node of text
function rows(target, data, none) {
	cbi_update_table(target, data.map(function(r) {
		return r.map(function(c) { return typeof c == 'string' ? document.createTextNode(c) : c; });
	}), none);
}

// a dialog; its title is text too
function modal(title, children) {
	ui.showModal([ String(title) ], children);
}

// a line or an address: whole, as it is - the text never taken for HTML
function mono(text) {
	return E('code', { 'style': 'font-size:1.05em; word-break:break-all; user-select:all' }, [ document.createTextNode(text) ]);
}

function quiet(text) {
	return E('span', { 'style': 'opacity:.7' }, [ text ]);
}

// the day of today, YYYY-MM-DD, by the clock of this computer
function today() {
	var d = new Date(), p = function(n) { return (n < 10 ? '0' : '') + n; };
	return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
}

// the details of something, in a tooltip: an ⓘ beside it - the page shows the names, the details when asked
function tip(text) {
	return E('span', { 'title': text, 'style': 'cursor:help; opacity:.6; margin-left:.35em; font-weight:normal; font-size:.9em' }, 'ⓘ');
}

// a note under something: plain, or a warning
function hint(text, warn) {
	return E('div', { 'class': warn ? 'alert-message warning' : 'cbi-section-descr', 'style': 'margin:.6em 0 0' }, [].concat(text));
}

function said(where, text) {
	dom.content(where, E('div', { 'class': 'alert-message warning', 'style': 'margin-top:.6em' }, [ text ]));
}

// words that tell a time since: they change by themselves, in their place - nothing around them is made anew for it
var living = [];
function live(words) {
	var s = E('span', {}, [ words() ]);
	living.push([ s, words ]);
	return s;
}
function relive() {
	living = living.filter(function(l) { return l[0].isConnected; });
	living.forEach(function(l) { var t = l[1](); if (l[0].textContent != t) l[0].textContent = t; });
}

// a small button, beside the others of a row
function small(label, click, kind, title) {
	return E('button', { 'class': 'btn cbi-button-' + (kind || 'neutral'), 'title': title || '', 'style': 'padding:0 .7em; line-height:1.9em; font-size:.85em; margin-left:.3em', 'click': click }, label);
}

// a small button that copies `text()`, and says so a moment; nothing to copy - it is off
function smallCopy(text, title) {
	var b = small(_('Copy'), function() {
		var t = text();
		if (!t) return;
		return copyText(t).then(function(ok) {
			b.textContent = ok ? _('Copied ✓') : _('Not copied');
			window.setTimeout(function() { b.textContent = _('Copy'); }, 2000);
		});
	}, 'action', title);
	if (!text()) b.disabled = 'disabled';
	return b;
}

// a moment, by the clock of this computer: 12:34:56 today, the day before it else
function clockOf(moment) {
	if (moment == null) return '-';
	var d = new Date(moment), p = function(n) { return (n < 10 ? '0' : '') + n; };
	var t = p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
	return d.toDateString() == new Date().toDateString() ? t : p(d.getDate()) + '.' + p(d.getMonth() + 1) + ' ' + t;
}

// a drop-down list: [ value, label ] each; a value there is that is none of them is shown too, as it is
function select(value, options, change) {
	value = value == null ? '' : String(value);
	if (!options.some(function(o) { return String(o[0]) == value; }))
		options = options.concat([ [ value, value ] ]);
	return E('select', { 'class': 'cbi-input-select', 'change': change }, options.map(function(o) {
		return E('option', { 'value': o[0], 'selected': String(o[0]) == value ? 'selected' : null }, [ String(o[1]) ]);
	}));
}

// the field of a dialog: its label, the field
function row(label, field, note) {
	return E('div', { 'style': 'display:grid; grid-template-columns:10em 1fr; gap:.6em; align-items:center; margin:.5em 0' }, [
		E('label', { 'style': 'opacity:.8' }, [ label, note ? tip(note) : '' ]), E('div', {}, field)
	]);
}

// a dialog with fields; `ok()` saves and applies - its message of what is wrong, or a promise
function dialog(title, fields, okLabel, ok) {
	var wrong = E('div');
	modal(title, fields.concat([ wrong, E('div', { 'class': 'right' }, [
		E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
		E('button', { 'class': 'btn cbi-button-positive', 'click': function() {
			var r = ok();
			if (typeof r == 'string')
				return said(wrong, r);
			ui.hideModal();
			return r;
		} }, okLabel)
	]) ]));
}

// the megabytes a user may carry: the choices
var LIMITS = [ [ '', _('No limit') ], [ '100', '100 MB' ], [ '1024', '1 GB' ], [ '10240', '10 GB' ], [ '102400', '100 GB' ], [ '1048576', '1 TB' ] ];

// a step of Get started: done - a tick, else its number
function step(n, done, children) {
	return E('li', { 'style': 'display:flex; gap:.6em; align-items:baseline; margin:.4em 0' + (done ? '; opacity:.65' : '') }, [
		E('span', { 'style': 'flex:none; width:1.5em; height:1.5em; line-height:1.5em; border-radius:50%; text-align:center; font-weight:bold; color:#fff; background:' + (done ? GOOD : INFO) }, done ? '✓' : String(n)),
		E('div', { 'style': 'flex:1; min-width:0' }, [].concat(children))
	]);
}

return view.extend({
	load: function() {
		// the settings: the forms load them themselves. The public address comes later: finding it may take seconds
		return Promise.all([ L.resolveDefault(callStatus(true, false), {}), uci.load('adhoc-relay') ]);
	},

	// the address of this router for the lines: the name in DNS its owner set, else its public address - of its wan, or found by
	// STUN - else the one a relay it reports its address to saw last; null - none
	address: function() {
		var seen = (this.st.reports || []).filter(function(r) { return r.answered != null && r.seen; })
			.sort(function(a, b) { return a.answered - b.answered; })[0];
		return uci.get('adhoc-relay', 'main', 'dns') || this.found.address || (seen ? seen.seen : null);
	},

	// the reports of the settings, with a read key: where the servers look up the address of this router - each port of it alike
	reports: function() {
		return uci.sections('adhoc-relay', 'report').map(function(s) { return parseTo(s.to); }).filter(function(r) { return r && r.read; });
	},

	// The line for the server, of the settings saved, as `adhoc-relay lines` makes it: <key>👉<address>:<first port>👉 - of the
	// password, of a fixed port, of a user, all alike: the server binds its port at the first port with the key, and the router
	// answers the port - any free one, or the fixed one of the key. When this router reports its address, with a read key, to
	// relays of fixed address, each line looks it up there - its address changes:
	// <key>🌐<read key>👉<relay>:<its port>🌐…🌐<the first port here>👉, the reports in order. null while something of it is missing
	lineOf: function(secret) {
		var port = first();
		if (!secret || !port) return null;
		var address = this.address(), reads = this.reports().map(function(r) { return r.read + ARROW + r.host + ':' + r.port; }).join(GLOBE);
		var where = reads ? GLOBE + reads + GLOBE + port : address ? ARROW + address + ':' + port : null;
		return where ? secret + where + ARROW : null;
	},

	// what the lines lack, in words: no address of this router; an IP that changes, its line of a relay with no read key; '' - nothing
	linesNote: function() {
		var reads = this.reports().length, changes = uci.sections('adhoc-relay', 'report').length > 0;
		return !reads && !this.address() ? _('The public IP of this router is not found, so the lines have none. Set a DNS name in Settings, or let a router of a fixed IP keep it: Changing IP.') :
			changes && !reads ? _('The lines hold the IP of today and stop working when it changes: the line pasted in Changing IP has no read key (%s). Ask the owner of that router for its line again.').format(EYES) :
			reads ? _('The IP of this router changes: the servers look it up at %s, the line holds where.').format(this.reports().map(function(r) { return r.host; }).join(', ')) : '';
	},

	// a new key - the password, or the key of a fixed port: asked first, as each server of it needs its new line then
	newKey: function(what, set, where) {
		var page = this;
		modal(_('A new key for %s').format(what), [
			E('p', _('The old one opens nothing from now on: each server that knocks with it needs its new line, copied after this.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-negative', 'click': function() { ui.hideModal(); set(newPassword()); return page.apply(where || page.portsSaid); } }, _('New key'))
			])
		]);
	},

	// the moment a port was used last, as it was shown first: each poll tells it in whole seconds ago, a second sooner or later
	// by the clock of this computer - the same moment must not look like another one
	moment: function(u) {
		var now = Date.now() - u.ago * 1000, was = this.usedAt[u.port];
		if (was == null || Math.abs(now - was) > 2500) this.usedAt[u.port] = was = now;
		return was;
	},

	// a fixed port added, or its name and port changed: its port of the free ones of the range - from the first + 1000 on, easy to
	// remember -, its key made by itself
	fixedDialog: function(s) {
		var page = this, taken = {}, ports = [];
		// by its section: the settings give each of them anew at every asking, never the same one twice
		uci.sections('adhoc-relay', 'fixed').forEach(function(x) { if (!s || x['.name'] != s['.name']) taken[x.port] = true; });
		for (var p = Math.min(first() + 1000, last()); p <= last() && ports.length < 50; p++)
			if (!taken[p]) ports.push([ String(p), String(p) ]);
		for (var q = first() + 1; q < Math.min(first() + 1000, last()) && ports.length < 60; q++)
			if (!taken[q]) ports.push([ String(q), String(q) ]);
		var name = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'value': s ? (s.name || '') : '', 'placeholder': _('such as office-rdp') });
		var port = select(s ? s.port : ports[0] && ports[0][0], ports);
		dialog(s ? _('Fixed port %s').format(s.port) : _('A fixed port'), [
			row(_('Name'), name, _('Letters, digits, - and _')),
			row(_('Port'), port, _('Its clients connect to it, always the same'))
		], s ? _('Save') : _('Add'), function() {
			if (!/^[A-Za-z0-9_-]*$/.test(name.value)) return _('A name of letters, digits, - and _');
			if (taken[port.value]) return _('Port %s is fixed already').format(port.value);
			var id = s ? s['.name'] : uci.add('adhoc-relay', 'fixed');
			// the users of the port follow it
			if (s && s.port != port.value)
				uci.sections('adhoc-relay', 'user').forEach(function(a) { if (a.of == s.port) uci.set('adhoc-relay', a['.name'], 'of', port.value); });
			uci.set('adhoc-relay', id, 'port', port.value);
			uci.set('adhoc-relay', id, 'name', name.value || null);
			if (!s) uci.set('adhoc-relay', id, 'key', newPassword());
			return page.apply(page.portsSaid);
		});
	},

	// a fixed port taken away, its users with it
	dropFixed: function(s) {
		var page = this, users = uci.sections('adhoc-relay', 'user').filter(function(a) { return a.of == s.port; });
		modal(_('Fixed port %s').format(s.port), [
			E('p', [ users.length ? _('Port %s is fixed no more: its key and its %d users open nothing from now on.').format(s.port, users.length) :
				_('Port %s is fixed no more: its key opens nothing from now on.').format(s.port) ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-negative', 'click': function() {
					ui.hideModal();
					users.forEach(function(a) { uci.remove('adhoc-relay', a['.name']); });
					uci.remove('adhoc-relay', s['.name']);
					return page.apply(page.portsSaid);
				} }, _('Take it away'))
			])
		]);
	},

	// the line of a record, for the router it is for - to paste into On my public IP change, notify the following relays there: ✏️<write key>👀<read key>👉<this
	// router>:<first port>; null - no address of this router, or no keys yet
	recordLine: function(s) {
		var read = L.toArray(s.read)[0], address = this.address();
		return s.write && read && address ? toLine({ write: s.write, read: read, host: address, port: first() }) : null;
	},

	// The ports, what is done with them: ♻️ the ports given at each start - by the password, or a user of it -, and ⚓ the fixed
	// ports, by their names. Each: when it was used last - its last meeting of the day -, from where, by which user, 🟢 while a
	// meeting goes on. The lines are not shown: Copy puts them in the clipboard. Made anew only when something of it changes, so that
	// a button keeps what it says a moment
	showPorts: function() {
		var st = this.st, page = this, used = {}, marked = {}, active = {}, isFixed = {};
		(st.used || []).forEach(function(u) { used[u.port] = u; });
		(st.marked || []).forEach(function(m) { marked[m.port] = m.user; });
		(st.meetings || []).forEach(function(m) { if (m.state == 'ESTABLISHED') active[m.port] = true; });
		var fixed = uci.sections('adhoc-relay', 'fixed').filter(function(s) { return s.port; });
		fixed.forEach(function(s) { isFixed[s.port] = true; });
		fixed.sort(function(a, b) { return (a.name || '￿').localeCompare(b.name || '￿') || a.port - b.port; });
		var given = (st.ports || []).filter(function(p) { return !isFixed[p.port]; }).sort(function(a, b) { return a.port - b.port; });
		var on = function(port) { return active[port] ? E('span', { 'title': _('in use now') }, '🟢') : ''; };
		// what the port does now, and how long it is held unless its server knocks: in the tooltip of its number
		var held = {};
		(st.ports || []).forEach(function(p) { held[p.port] = p; });
		var number = function(port) {
			var p = held[port];
			return p ? E('span', { 'title': portState(p) + ' · ' + _('free in %s unless its server knocks').format(nftSpan(p.free)), 'style': 'cursor:help' }, [ String(port) ]) : String(port);
		};
		var when = function(u) { return u ? clockOf(page.moment(u)) : '-'; };
		var sig = JSON.stringify([ given.map(function(p) { var u = used[p.port]; return [ p.port, marked[p.port], when(u), u && u.from, active[p.port], portState(p) ]; }),
			fixed.map(function(s) { var u = used[s.port], h = held[s.port]; return [ s.name, s.port, s.key, when(u), u && u.from, u && u.user, active[s.port], h && portState(h) ]; }),
			this.lineOf('x', true, 1), this.linesNote() ]);
		if (sig === this.portsSig) return;
		this.portsSig = sig;
		rows(this.givenTable, given.map(function(p) {
			var u = used[p.port];
			return [ marked[p.port] || quiet('—'), number(p.port), when(u), u ? u.from : '-', on(p.port) ];
		}), E('em', _('No server holds a port now')));
		rows(this.fixedTable, fixed.map(function(s) {
			var u = used[s.port];
			return [ E('a', { 'href': '#', 'title': _('Name and port'), 'click': function(ev) { ev.preventDefault(); page.fixedDialog(s); } }, [ s.name || quiet(_('(no name)')) ]),
				number(s.port), when(u), u ? u.from : '-', u && u.user ? u.user : '', on(s.port),
				E('span', { 'style': 'white-space:nowrap' }, [
					smallCopy(function() { return page.lineOf(s.key, false, s.port); }, _('The line of its server')),
					small(_('New key'), function() { page.newKey(_('fixed port %s').format(s.port), function(k) { uci.set('adhoc-relay', s['.name'], 'key', k); }); }),
					small('✕', function() { page.dropFixed(s); }, 'negative', _('Take it away'))
				]) ];
		}), E('em', _('None yet: Add')));
		var note = this.linesNote();
		dom.content(this.portsNote, note ? hint(note, /not found|stop working/.test(note)) : '');
		dom.content(this.passwordButtons, [
			smallCopy(function() { return page.lineOf(uci.get('adhoc-relay', 'main', 'password'), true, first()); }, _('The line of the password: a server asks a port with it')),
			small(_('New key'), function() { page.newKey(_('the password'), function(k) { uci.set('adhoc-relay', 'main', 'password', k); }); })
		]);
	},

	// the top: one card - whether the router serves, its IP, ports and what goes on; the steps to start, until it serves
	showRouter: function() {
		var st = this.st, page = this, address = this.address(), dns = uci.get('adhoc-relay', 'main', 'dns');
		var reports = uci.sections('adhoc-relay', 'report'), records = uci.sections('adhoc-relay', 'record');
		var password = uci.get('adhoc-relay', 'main', 'password'), enabled = uci.get('adhoc-relay', 'main', 'enabled') != '0';
		var link = function(text, tab) { return E('a', { 'href': '#', 'click': function(ev) { ev.preventDefault(); page.go(tab); } }, text); };
		var running = st.running && st.giving && password;
		var colour = running ? GOOD : st.running ? BAD : WARN;
		var state = running ? [ E('strong', {}, _('Running')), ' - ', _('servers get ports here, their clients reach them.') ] :
			st.running && !st.giving && st.missing ? [ E('strong', {}, _('Almost ready')), ' - ', _('the packages %s of OpenWrt are being installed: they come as soon as the router reaches the internet, and AdHoc Relay starts by itself.').format(st.missing) ] :
			st.running && !st.giving ? [ E('strong', {}, _('Not serving')), ' - ', _('the rules are loaded, but the service that gives ports has stopped. Restart adhoc-relay in System > Startup.') ] :
			st.running ? [ E('strong', {}, _('Not serving')), ' - ', _('there is no password: servers cannot ask for a port.') ] :
			!enabled ? [ E('strong', {}, _('Turned off')), ' - ', _('turn it on in Settings, or below.') ] :
			[ E('strong', {}, _('Not running')), ' - ', _('see the steps below.') ];

		var ip;
		if (reports.length) {
			var answered = (st.reports || []).filter(function(r) { return r.answered != null; }).sort(function(a, b) { return a.answered - b.answered; })[0];
			// its address is the one the relay of fixed IP saw last: the servers look that one up
			if (answered && answered.seen)
				address = answered.seen;
			var hosts = reports.map(function(s) { var r = parseTo(s.to); return r ? r.host : '?'; }).join(', ');
			// how long ago: told anew by itself, the card is not made anew for it
			var newest = function() {
				var a = (page.st.reports || []).filter(function(r) { return r.answered != null; }).sort(function(x, y) { return x.answered - y.answered; })[0];
				return a ? _('changes · reported to %s, %s').format(hosts, agoText(a.answered)) : _('changes · not reported yet');
			};
			ip = [ address ? mono(address) : '', address ? ' ' : '', E('span', { 'style': 'opacity:.7' }, [ live(newest) ]), ' ', link(_('Details'), 'address') ];
		} else if (address) {
			ip = [ mono(address), ' ', quiet(dns ? _('fixed · DNS name') : _('fixed · found automatically')), ' ', link(_('It changes?'), 'address') ];
		} else {
			ip = [ E('span', { 'style': 'color:' + WARN }, _('Not found.')), ' ', link(_('Set a DNS name'), 'settings') ];
		}
		// the connections there are: one being set up, or closed and not forgotten by the kernel yet, is none
		var given = st.ports_all != null ? st.ports_all : (st.ports || []).length, met = (st.meetings || []).filter(function(m) { return m.state == 'ESTABLISHED'; }).length;
		// made anew only when something of it changes: what is selected in it, to copy, stays selected
		var sig = JSON.stringify([ !!st.running, !!st.giving, st.missing, st.failed, !!password, enabled, address, dns, this.found, given, met,
			reports.map(function(s) { return s.to; }), records.map(function(s) { return s.name; }),
			(st.reports || []).map(function(r) { return [ r.to, r.answered != null, r.seen ]; }),
			(st.records || []).map(function(r) { return r.name; }), first(), last() ]);
		if (sig === this.routerSig) return;
		this.routerSig = sig;
		var facts = [
			[ _('Public IP'), ip ],
			[ _('Ports'), [ String(first()), ' ', quiet(_('takes the requests')), ' · ', '%d-%d'.format(first() + 1, last()), ' ', quiet(_('go to servers')) ] ],
			st.running ? [ _('Now'), [ given == 1 ? _('1 port held') : _('%d ports held').format(given), ' · ', met == 1 ? _('1 connection') : _('%d connections').format(met), ' ', link(_('Details'), 'ports') ] ] : null,
			records.length ? [ _('Tracks the public IP of'), records.reduce(function(all, s, i) {
				var since = function() {
					var w = (page.st.records || []).filter(function(r) { return r.name == s.name; })[0];
					return w ? _('(%s)').format(agoText(w.ago)) : _('(no report yet)');
				};
				return all.concat([ (i ? ', ' : '') + s.name + ' ', live(since) ]);
			}, []).concat([ ' ', link(_('Details'), 'address') ]) ] : null
		].filter(function(f) { return f; });

		// until it serves: the steps there, each with its button
		var steps = '';
		if (!running) {
			var fix = !password ? E('button', { 'class': 'btn cbi-button-apply', 'click': function() {
					// into the fields of Settings: their save writes them, and would write an empty field over a value set aside
					var field = function(name) { return page.mMain.lookupOption(name, 'main')[0].getUIElement('main'); };
					field('password').setValue(newPassword());
					field('enabled').setValue('1');
					return page.apply(page.startSaid);
				} }, _('Create a password and start')) :
				!enabled ? E('button', { 'class': 'btn cbi-button-apply', 'click': function() {
					page.mMain.lookupOption('enabled', 'main')[0].getUIElement('main').setValue('1');
					return page.apply(page.startSaid);
				} }, _('Turn on and start')) : '';
			var n = 0;
			steps = E('div', { 'style': 'margin-top:.8em; padding-top:.6em; border-top:1px solid rgba(127,127,127,.25)' }, [
				E('strong', {}, _('Get started')),
				E('ol', { 'style': 'list-style:none; margin:.3em 0 0; padding:0' }, [
					step(++n, password && enabled, [ password && enabled ? _('A password is set, AdHoc Relay is on.') : _('Create a password: servers ask for a port with it.'), ' ', fix ]),
					this.found.wan ? step(++n, false, _('Forward the ports %d-%d, TCP and UDP, on the router in front of this one to its WAN address %s.').format(first(), last(), this.found.wan)) : '',
					step(++n, false, [ _('Give a server its line:'), ' ', link(_('Ports'), 'ports'), ', ', _('Copy') ])
				]),
				this.startSaid
			]);
		}
		dom.content(this.top, [
			E('div', { 'style': 'border:1px solid rgba(127,127,127,.35); border-left:4px solid ' + colour + '; border-radius:6px; padding:.8em 1em; margin:.6em 0 1em' }, [
				E('div', { 'style': 'margin-bottom:.6em' }, [ E('span', { 'style': 'color:' + colour + '; font-size:1.2em' }, '● ') ].concat(state)),
				E('div', { 'style': 'display:grid; grid-template-columns:max-content 1fr; gap:.35em 1.5em; align-items:baseline' },
					facts.reduce(function(all, f) { return all.concat([ E('span', { 'style': 'opacity:.7' }, f[0]), E('span', {}, f[1]) ]); }, [])),
				// the last load of the rules failed: what runs is not of the settings there are
				st.failed ? hint([ _('The settings are not applied: %s').format(st.failed), tip(_('The rules of AdHoc Relay did not load with the settings there are: the rules of before run on, or none. The log of the router - Status > System Log, adhoc-relay - has what was said. Correct the settings and save them again.')) ], true) : '',
				this.found.wan && running ? hint(_('This router is behind another router or the NAT of its provider: its WAN address is %s. Forward the ports %d-%d, TCP and UDP, to it there.').format(this.found.wan, first(), last()), true) : '',
				steps
			])
		]);
	},

	// goes to the tab `name`
	go: function(name) {
		var a = document.querySelector('.cbi-tabmenu li[data-tab="' + name + '"] a');
		if (a) a.click();
		window.scrollTo(0, 0);
	},

	// Save & Apply at the bottom: on Settings alone - the other tabs save and apply what is done at once
	footer: function(tab) {
		if (tab) this.tab = tab;
		var f = document.querySelector('.cbi-page-actions');
		if (f) f.style.display = this.tab == 'settings' ? '' : 'none';
	},

	// the tab shown now
	shownTab: function() {
		var li = document.querySelector('.cbi-tabmenu li.cbi-tab');
		return (li && li.getAttribute('data-tab')) || 'ports';
	},

	update: function(st) {
		// a part not asked for this time stays as it was
		var was = this.st || {}, page = this;
		if (st.meetings == null) st.meetings = was.meetings;
		if (st.ports == null) { st.ports = was.ports; st.used = was.used; st.marked = was.marked; }
		if (st.tries == null) { st.tries = was.tries; st.tries_all = was.tries_all; }
		this.st = st;
		this.showRouter();
		this.showPorts();
		this.showKept();
		this.showReports();
		this.showUsers();
		this.showTags();
		relive();
		var blocked = st.blocked || [];
		this.blockedBox.style.display = blocked.length ? '' : 'none';
		// the list has the first of them: how many there are in all
		this.blockedCount.textContent = ' (' + (st.blocked_all != null ? st.blocked_all : blocked.length) + ')';
		if (blocked.length || this.hadBlocked)
			rows(this.blocked, blocked.map(function(b) {
				return [ b.address, b.port ? _('Guessed passwords at port %d: blocked at that port only').format(b.port) : _('Wrong passwords or keys: blocked at every port'), nftSpan(b.ends),
					small(_('Unblock'), function() { return L.resolveDefault(callUnblock(b.address, b.port || 0), null).then(function() { if (page.fresh) return page.fresh(); }); },
						null, _('Let it in again now: its count of wrong ones is forgotten too')) ];
			}), E('em', _('No address is blocked')));
		this.hadBlocked = blocked.length > 0;
		this.showTries();
	},

	// The last 10 minutes: off unless turned on here - the router notes nothing then, and each note is work for it. Its rows
	// only while it is open: folded, nothing is made of them. On or off as the settings say: the rules load a moment after
	showTries: function() {
		if (!this.triesBox.open) return;
		var page = this, st = this.st, tries = st.tries || [], on = uci.get('adhoc-relay', 'main', 'log') == '1';
		var more = on && st.tries_all > tries.length ? _('The newest %d of %d.').format(tries.length, st.tries_all) : '';
		// made anew only when it changes: a button drawn again under a click would lose it
		var sig = on + '|' + more;
		if (sig !== this.triesSig) {
			this.triesSig = sig;
			dom.content(this.triesNote, [ more ? more + ' ' : '', quiet(on ? _('On: turn it off when done.') : _('Off: nothing is noted.')), ' ',
				small(on ? _('Turn off') : _('Turn on'), function() {
					uci.set('adhoc-relay', 'main', 'log', on ? '0' : '1');
					return Promise.resolve(page.apply(page.portsSaid)).then(function() {
						page.showTries();
						// the rules load a moment after the settings are applied: what they note is asked for then
						window.setTimeout(function() { if (page.fresh) page.fresh(); }, 3000);
					});
				}) ]);
		}
		this.tries.style.display = on ? '' : 'none';
		if (!on) return;
		rows(this.tries, tries.map(function(t) {
			return [ agoText(t.ago), t.from, t.port, tryWords[t.what] || t.what ];
		}), E('em', _('Nothing in the last 10 minutes')));
	},

	// a section taken away at once, asked first: `what` in words
	drop: function(id, what, after, where) {
		var page = this;
		modal(what, [
			E('p', _('Take it away?')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-negative', 'click': function() {
					ui.hideModal();
					uci.remove('adhoc-relay', id);
					if (after) after();
					return page.apply(where || page.addressSaid);
				} }, _('Take it away'))
			])
		]);
	},

	// the routers whose addresses this one keeps: each its line to copy, when it reported last
	showKept: function() {
		var st = this.st, page = this;
		var sig = JSON.stringify([ (st.records || []).map(function(r) { return [ r.name, r.address ]; }), uci.sections('adhoc-relay', 'record').map(function(s) { return [ s.name, page.recordLine(s) ]; }) ]);
		if (sig === this.keptSig) return;
		this.keptSig = sig;
		var list = uci.sections('adhoc-relay', 'record').map(function(s) {
			var w = (st.records || []).filter(function(r) { return r.name == s.name; })[0];
			// how long ago it reported: told anew in its place, the row - its buttons - stays
			var since = function() { var n = (page.st.records || []).filter(function(r) { return r.name == s.name; })[0]; return n ? agoText(n.ago) : '-'; };
			return [ E('strong', {}, [ s.name || '?' ]), w ? w.address : E('em', {}, _('no report yet: paste its line there')), live(since),
				E('span', { 'style': 'white-space:nowrap' }, [
					smallCopy(function() { return page.recordLine(s); }, _('Its line: paste it on that router, under On my public IP change, notify the following relays')),
					small('✕', function() {
						// its read users go with it
						page.drop(s['.name'], _('The IP of %s').format(s.name), function() {
							uci.sections('adhoc-relay', 'user').forEach(function(a) { if (a.of == '@' + s.name) uci.remove('adhoc-relay', a['.name']); });
						});
					}, 'negative', _('Keep it no more'))
				]) ];
		});
		rows(this.keptTable, list, E('em', _('None yet')));
	},

	// whom this router reports its own address to: the answers
	showReports: function() {
		var st = this.st, page = this;
		var sig = JSON.stringify([ (st.reports || []).map(function(r) { return [ r.to, r.seen ]; }), uci.sections('adhoc-relay', 'report').map(function(s) { return s.to; }) ]);
		if (sig === this.reportsSig) return;
		this.reportsSig = sig;
		var list = uci.sections('adhoc-relay', 'report').map(function(s) {
			var r = parseTo(s.to) || {}, to = r.host + ':' + r.port, now = (st.reports || []).filter(function(x) { return x.to == to; })[0];
			// when it answered last: told anew in its place, the row stays
			var since = function() { var n = (page.st.reports || []).filter(function(x) { return x.to == to; })[0]; return n && n.answered != null ? agoText(n.answered) : _('no answer yet'); };
			return [ r.host ? to : String(s.to || ''), r.read ? _('yes') : E('span', { 'style': 'color:' + WARN }, _('no: the line has no read key')),
				live(since), now && now.seen ? now.seen : '-',
				small('✕', function() { page.drop(s['.name'], _('Reporting to %s').format(r.host || s.to)); }, 'negative', _('Report to it no more')) ];
		});
		rows(this.reportsTable, list, E('em', _('Nobody: for the servers the IP of this router does not change')));
	},

	// the line of a user for the server it is given to: as the line of the password or of its fixed port, with the user in place
	// of their key; null - a user of a read key, or no address of this router
	userLine: function(s) {
		return s.of == 'password' ? this.lineOf(s.key, true, first()) : /^\d+$/.test(s.of || '') ? this.lineOf(s.key, false, s.of) : null;
	},

	// the names of the tags, by number; and the choices of the tags: those named, then those only numbers of users have
	tagNames: function() {
		var names = {}, all = {};
		uci.sections('adhoc-relay', 'tag').forEach(function(t) { names[t.id] = t.name; all[t.id] = t.name + ' (' + t.id + ')'; });
		uci.sections('adhoc-relay', 'user').forEach(function(a) { tagsOf(a).forEach(function(n) { if (all[n] == null) all[n] = String(n); }); });
		return { names: names, choices: all };
	},

	// what a user is using: the choices - the password, each fixed port, the read key of each record
	ofChoices: function() {
		return [ [ 'password', '♻️ ' + _('any free port') ] ]
			.concat(uci.sections('adhoc-relay', 'fixed').filter(function(f) { return f.port; }).map(function(f) { return [ f.port, '⚓ ' + (f.name ? f.name + ' · ' : '') + f.port ]; }))
			.concat(uci.sections('adhoc-relay', 'record').map(function(r) { return [ '@' + r.name, '🌐 ' + _('the IP of %s').format(r.name) ]; }));
	},

	// a user added, or changed: its name, what it is using, its last day, its limit or the direct path only, its tags -
	// lists to choose from; a new one gets a key of its own
	userDialog: function(s) {
		var page = this, t = this.tagNames();
		var name = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'value': s ? (s.name || '') : '', 'placeholder': _('whom it is given to') });
		// the direct path only: nothing goes through this router, a limit has nothing to count. A read key meets nobody
		var direct = E('input', { 'type': 'checkbox', 'checked': s && s.direct == '1' ? 'checked' : null });
		var limit = select(s ? (s.limit || '') : '', LIMITS);
		var of = select(s ? s.of : 'password', this.ofChoices(), function() { shown(); });
		var shown = function() {
			var read = /^@/.test(of.value);
			direct.disabled = read;
			limit.disabled = read || direct.checked;
		};
		direct.addEventListener('change', shown);
		shown();
		var until = E('input', { 'class': 'cbi-input-text', 'type': 'date', 'value': s ? (s.expires || '') : '', 'min': today() });
		var tags = new ui.Dropdown(s ? L.toArray(s.tags) : [], t.choices, { multiple: true, create: true, optional: true, sort: true,
			select_placeholder: _('none'), custom_placeholder: _('a number of 0-255…'), validate: function(v) { return /^\d+$/.test(v) && +v <= 255 || _('A number of 0-255'); } });
		dialog(s ? _('User %s').format(s.name || '') : _('A user'), [
			row(_('Name'), name),
			row(_('Using'), of, _('What its key opens: any free port, as the password does; a fixed port, as its key does; the IP of a record, as its read key does')),
			row(_('Until'), until, _('Its last day; empty - always')),
			row(_('Direct only'), E('label', {}, [ direct, ' ', _('Traffic can be passed via a direct connection only') ])),
			row(_('Limit'), limit, _('What its meetings may carry through this router. A limit is more work for the router: it counts every packet of the meetings of this user, and they stay out of its fast path. No limit: nothing is counted.')),
			row(_('Tags'), tags.render(), _('8 at most: choose, or type a number'))
		], s ? _('Save') : _('Add'), function() {
			var chosen = L.toArray(tags.getValue()).map(Number).filter(function(v, i, a) { return v >= 0 && v <= 255 && a.indexOf(v) == i; });
			if (!/^[A-Za-z0-9_-]*$/.test(name.value)) return _('A name of letters, digits, - and _');
			if (chosen.length > 8) return _('8 tags at most');
			// the firewall carries every connection past the count while its offloading is on: a limit set then would limit nothing
			if (limit.value && !direct.checked && !/^@/.test(of.value) && page.st.flow_offloading)
				return _('A limit does not hold while Software flow offloading of the firewall is on. Turn it off in Network > Firewall, then set the limit.');
			// a user of a port has a number of 1-255: one more would be left out by the rules, and open nothing
			if (!/^@/.test(of.value) && uci.sections('adhoc-relay', 'user').filter(function(a) { return !/^@/.test(a.of || '') && (!s || a['.name'] != s['.name']); }).length >= 255)
				return _('255 users of ports at most');
			var id = s ? s['.name'] : uci.add('adhoc-relay', 'user');
			if (!s) uci.set('adhoc-relay', id, 'key', newPassword());
			uci.set('adhoc-relay', id, 'name', name.value || null);
			uci.set('adhoc-relay', id, 'of', of.value);
			uci.set('adhoc-relay', id, 'expires', until.value || null);
			var only = direct.checked && !/^@/.test(of.value);
			uci.set('adhoc-relay', id, 'direct', only ? '1' : null);
			uci.set('adhoc-relay', id, 'limit', only ? null : limit.value || null);
			uci.set('adhoc-relay', id, 'tags', chosen.length ? chosen.map(String) : null);
			return page.apply(page.userSaid);
		});
	},

	// the users chosen by the tags: what each is of, until when, what its meetings carried of its limit, its tags; Copy, New key,
	// take away
	showUsers: function() {
		var st = this.st, page = this, want = L.toArray(this.tagFilter.getValue()).map(Number), any = this.tagAny.value == 'any';
		var names = this.tagNames().names, carried = {};
		(st.users || []).forEach(function(a) { carried[a.key] = a; });
		this.shown = uci.sections('adhoc-relay', 'user').filter(function(s) { return tagged(s, want, any); })
			.sort(function(a, b) { return (a.name || '￿').localeCompare(b.name || '￿'); });
		var ofText = {};
		this.ofChoices().forEach(function(o) { ofText[o[0]] = o[1]; });
		var list = this.shown.map(function(s) {
			var c = carried[s.key], read = /^@/.test(s.of || '');
			var over = c && c.limit != null && c.kbytes >= c.limit * 1024;
			// counted of a user with a limit alone
			var used = read || (s.direct != '1' && !(+s.limit > 0)) ? '-' : s.direct == '1' ? _('direct only') : E('span', over ? { 'style': 'color:' + BAD } : {}, [ (bytesText((c ? c.kbytes : 0) * 1024) || '0 B') + (s.limit ? ' / ' + bytesText(s.limit * 1048576) : '') ]);
			var expired = s.expires && s.expires < today();
			return [ E('a', { 'href': '#', 'click': function(ev) { ev.preventDefault(); page.userDialog(s); } }, [ s.name || quiet(_('(no name)')) ]),
				String(ofText[s.of] || s.of || '?'), expired ? E('span', { 'style': 'color:' + BAD }, [ s.expires ]) : String(s.expires || _('always')), used,
				tagsOf(s).map(function(n) { return names[n] || n; }).join(', ') || '-',
				E('span', { 'style': 'white-space:nowrap' }, [
					smallCopy(function() { return page.userLine(s) || s.key; }, read ? _('The key') : _('The line of its server')),
					small(_('New key'), function() { page.newKey(_('the user %s').format(s.name || ''), function(k) { uci.set('adhoc-relay', s['.name'], 'key', k); }, page.userSaid); }),
					small('✕', function() { page.drop(s['.name'], _('The user %s').format(s.name || ''), null, page.userSaid); }, 'negative', _('Take it away: it opens nothing'))
				]) ];
		});
		// the offloading of the firewall carries the meetings of users past their count: said here, where a limit is set and read
		if (!!st.offloading !== this.offloadingSaid) {
			this.offloadingSaid = !!st.offloading;
			dom.content(this.usersNote, st.offloading ? hint([ _('Limits do not hold: Software flow offloading of the firewall is on.'),
				tip(_('The firewall of the router carries every connection on its own fast path, past the count of AdHoc Relay: what the meetings of the users with a limit carry is not counted, the limit does not stop them, and such a user taken away keeps the meetings it has. Turn it off in Network > Firewall: the other meetings have the fast path of AdHoc Relay then.')) ], true) : '');
		}
		var sig = JSON.stringify([ want, any, st.users || [], this.shown.map(function(s) { return [ s.name, s.of, s.expires, s.limit, s.direct, s.tags, s.key, page.userLine(s) ]; }), ofText ]);
		this.dropShown.disabled = want.length && this.shown.length ? null : 'disabled';
		if (sig === this.userSig) return;
		this.userSig = sig;
		rows(this.userTable, list, E('em', want.length ? _('No user has these tags') : _('None yet: Add a user')));
	},

	// the names of the tags: each a number and its name, taken away by ✕; one more by a number not named yet and a name
	showTags: function() {
		var page = this, tags = uci.sections('adhoc-relay', 'tag').sort(function(a, b) { return a.id - b.id; });
		var sig = JSON.stringify(tags.map(function(t) { return [ t.id, t.name ]; }));
		if (sig === this.tagsSig) return;
		this.tagsSig = sig;
		var named = {};
		tags.forEach(function(t) { named[t.id] = true; });
		var free = [];
		for (var i = 0; i < 256; i++) if (!named[i]) free.push([ String(i), String(i) ]);
		var number = select(free.length ? free[0][0] : '', free);
		var name = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'placeholder': _('such as partners'), 'style': 'width:12em' });
		dom.content(this.tagsBox, [
			E('div', { 'style': 'display:flex; flex-wrap:wrap; gap:.4em; margin:.4em 0' }, tags.length ? tags.map(function(t) {
				return E('span', { 'style': 'border:1px solid rgba(127,127,127,.4); border-radius:1em; padding:.1em .3em .1em .8em' }, [
					t.name + ' · ' + t.id, small('✕', function() { page.drop(t['.name'], _('The name of tag %s').format(t.id), null, page.userSaid); }, 'neutral', _('Its name only: the users keep the number')) ]);
			}) : [ quiet(_('No tag is named yet')) ]),
			E('div', { 'style': 'display:flex; flex-wrap:wrap; gap:.5em; align-items:center' }, [ number, name, E('button', { 'class': 'btn cbi-button-add', 'click': function() {
				if (!/^[A-Za-z0-9_-]+$/.test(name.value) || /^\d+$/.test(name.value)) return said(page.userSaid, _('A name of letters, digits, - and _, not a number'));
				// by the settings as they are now, not as they were when this was drawn: a second click finds what the first added
				if (uci.sections('adhoc-relay', 'tag').some(function(t) { return t.name == name.value || t.id == number.value; })) return said(page.userSaid, _('A tag is named %s already').format(name.value));
				var id = uci.add('adhoc-relay', 'tag');
				uci.set('adhoc-relay', id, 'id', number.value);
				uci.set('adhoc-relay', id, 'name', name.value);
				return page.apply(page.userSaid);
			} }, _('Name it')) ])
		]);
	},

	// the forms saved one after another: each sends what uci holds, and together they would send a new section several times
	handleSave: function(ev) {
		var maps = Array.prototype.slice.call(document.getElementById('maincontent').querySelectorAll('.cbi-map'));
		return maps.reduce(function(done, map) {
			return done.then(function() { return dom.callClassMethod(map, 'save'); });
		}, Promise.resolve());
	},

	// saves the forms and applies them: what a click on Add did works at once. What is wrong - a field of the forms, a key twice - is
	// said in `where`, and nothing is kept
	apply: function(where) {
		var page = this;
		return this.handleSaveApply(null, '0').catch(function(e) {
			// what was not saved is forgotten, and the settings there are read again: without them every table would be empty,
			// and the next Add would be checked against nothing
			uci.unload('adhoc-relay');
			return uci.load('adhoc-relay').then(function() {
				page.routerSig = page.portsSig = page.keptSig = page.reportsSig = page.userSig = page.tagsSig = null;
				page.update(page.st);
				said(where, _('Not saved: %s').format(e.message || e));
			});
		});
	},

	// a map of one part of the settings: keys twice are found on its save, across all the parts - none is saved then
	map: function(title) {
		var m = new form.Map('adhoc-relay', title), page = this;
		m.save = function(cb, silent) {
			return form.Map.prototype.save.call(this, function() {
				var found = twice();
				if (found)
					throw new Error(found);
				return cb ? cb() : null;
			}, silent).then(function(r) {
				page.routerSig = page.portsSig = page.keptSig = null;
				page.update(page.st);
				return r;
			});
		};
		return m;
	},

	render: function(data) {
		var st = data[0], page = this;
		// the public address of the router, and the address of its wan when that is not it: asked now, shown when it comes
		this.found = {};
		L.resolveDefault(callAddress(), {}).then(function(found) {
			page.found = found || {};
			page.routerSig = page.portsSig = page.keptSig = null;
			page.update(page.st);
		});
		this.st = st;
		this.usedAt = {};
		this.top = E('div');
		this.startSaid = E('div');
		// ── the ports: ♻️ the ports given at each start, ⚓ the fixed ports - their tables, the buttons of the password ──
		this.givenTable = table([ _('User'), _('Port'), _('Last used'), _('From'), '' ]);
		this.fixedTable = table([ _('Name'), _('Port'), _('Last used'), _('From'), _('User'), '', '' ]);
		this.passwordButtons = E('span');
		this.portsNote = E('div');
		this.portsSaid = E('div');

		// ── the users: chosen by their tags - each of them, or any -, a group taken away at once ──
		this.userTable = table([ _('Name'), _('Using'), _('Until'), _('Carried'), _('Tags'), '' ]);
		this.tagFilter = new ui.Dropdown([], this.tagNames().choices, { multiple: true, optional: true, sort: true, select_placeholder: _('all the users') });
		var tagFilter = this.tagFilter.render();
		tagFilter.addEventListener('cbi-dropdown-change', function() { page.showUsers(); });
		this.tagAny = select('each', [ [ 'each', _('with each of the tags') ], [ 'any', _('with any of the tags') ] ], function() { page.showUsers(); });
		this.userSaid = E('div');
		this.usersNote = E('div');
		this.tagsBox = E('div');
		// the users shown - those with the tags chosen - taken away at once: they open nothing, their meetings going on end
		this.dropShown = small(_('Take away those shown'), function() {
			if (!page.shown || !page.shown.length) return;
			modal(_('Take away %d users').format(page.shown.length), [
				E('p', [ _('They open nothing from now on, and their meetings going on end: %s').format(page.shown.map(function(s) { return s.name || s.key; }).join(', ')) ]),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
					E('button', { 'class': 'btn cbi-button-negative', 'click': function() {
						ui.hideModal();
						page.shown.forEach(function(s) { uci.remove('adhoc-relay', s['.name']); });
						return page.apply(page.userSaid);
					} }, _('Take them away'))
				])
			]);
		}, 'negative');
		this.dropShown.disabled = 'disabled';

		// ── the settings: one map, its options - a list to choose from wherever a list fits ──
		var mMain = this.mMain = this.map(), s = mMain.section(form.NamedSection, 'main', 'adhoc-relay');
		// the choices of a list; a value the settings have that is none of them is a choice too
		function choices(o, list) {
			list.forEach(function(c) { o.value(c[0], c[1]); });
			o.load = function(id) {
				var v = uci.get('adhoc-relay', id, this.option);
				if (v != null && this.keylist.indexOf(String(v)) < 0) this.value(String(v), String(v));
				return v;
			};
		}
		s.tab('basic', _('Basic'));
		s.tab('ports', _('Ports'));
		s.tab('guard', _('Protection'));
		var o = s.taboption('basic', form.Flag, 'enabled', _('Enabled'), _('Off: no rules and no ports; the settings stay.'));
		o.default = o.enabled;
		o.rmempty = false;
		o = s.taboption('basic', form.Value, 'password', _('Password'),
			_('16 letters or digits. Servers ask for a port with it. ♻️ Copy and New key are in Ports too.'));
		o.password = true;
		o.rmempty = false;
		o.validate = function(id, value) { return /^[A-Za-z0-9]{16}$/.test(value) || _('Exactly 16 letters or digits'); };
		o = s.taboption('basic', form.Value, 'dns', _('DNS name'),
			_('Optional. A name in DNS that points to this router: the lines carry it instead of the IP. Empty: the public IP, found automatically.'));
		// a name or an IPv4 address: the relay speaks IPv4 only, and a line takes no other
		o.datatype = 'host(1)';
		o.placeholder = _('found automatically');
		o = s.taboption('ports', form.Value, 'first', _('First port'), _('Servers ask this port for a port. The ports after it, up to the last, are given to servers.'));
		o.datatype = 'port';
		o.placeholder = '40000';
		var range = { first: o };
		o = s.taboption('ports', form.Value, 'last', _('Last port'), _('This router opens the range in its own firewall. A router in front of it must forward the range to it, TCP and UDP.'));
		o.datatype = 'port';
		o.placeholder = '49999';
		range.last = o;
		// The range as the rules load it: the first below the last - else no rules load at all, and the page says Not running with
		// no reason -, no zeros in front - nft takes such a number for one of base 8 -, every fixed port inside it - one left
		// outside is left out by the rules, and its line opens nothing
		[ 'first', 'last' ].forEach(function(n) {
			range[n].validate = function(id, v) {
				var other = range[n == 'first' ? 'last' : 'first'].formvalue(id);
				var f = +((n == 'first' ? v : other) || 40000), l = +((n == 'last' ? v : other) || 49999);
				if (v && !/^[1-9][0-9]*$/.test(v)) return _('A port, no zero in front');
				if (!(f < l)) return _('The last port must be above the first');
				var out = uci.sections('adhoc-relay', 'fixed').filter(function(x) { return +x.port <= f || +x.port > l; })[0];
				return out ? _('Fixed port %s is outside these ports').format(out.port) : true;
			};
		});
		o = s.taboption('ports', form.ListValue, 'wait', _('Hold'), _('How long a server keeps its port after its last knock: at least 10 s more than Knock every, so a knock that comes late loses nothing.'));
		choices(o, [ [ '30', _('30 s') ], [ '60', _('1 min') ], [ '120', _('2 min') ], [ '300', _('5 min') ], [ '600', _('10 min') ], [ '1800', _('30 min') ], [ '3600', _('1 h') ] ]);
		o.default = '60';
		var hold = o;
		// The times of the servers: the router tells each server them when it binds its port. A knock may come late, and the
		// port must stay open till the next one: Hold 10 s more than the knock at least - as `rules` and `adhoc-relay api` take them
		o = s.taboption('ports', form.ListValue, 'knock', _('Knock every'), _('How often a waiting server knocks to keep its port open. Its NAT must remember a knock until the next one: most remember 30 s or more, some less - a server behind such a NAT loses its port. Knocks are a small part of what a waiting server costs the router.'));
		choices(o, [ [ '10', _('10 s') ], [ '15', _('15 s') ], [ '20', _('20 s') ], [ '25', _('25 s') ] ]);
		o.default = '20';
		var knock = o;
		hold.validate = function(id, v) {
			return +(v || 60) >= +(knock.formvalue(id) || 20) + 10 ? true : _('At least 10 s more than Knock every');
		};
		o = s.taboption('ports', form.ListValue, 'dial', _('Dial try'), _('How long one dialing try of a waiting server lasts. Within a try its system sends the SYN again after 1, 3, 7 and 15 s, and the router looks at every SYN: they are most of what a waiting server costs it. 31 s sends a quarter of the SYNs of 3 s - a third from Windows, which ends a try at 21 s -, and the router holds about three times as many waiting servers. Clients connect as fast. A server started again on the same port takes it back at once behind a NAT that keeps its port, as most do; behind one that does not, within about half the try.'));
		choices(o, [ [ '3', _('3 s') ], [ '7', _('7 s') ], [ '15', _('15 s') ], [ '31', _('31 s') ] ]);
		o.default = '31';
		o = s.taboption('ports', form.ListValue, 'rebind', _('Bind again every'), _('How often a server binds its port again. Each bind is work for the router, as much as a few hundred SYNs. A server also binds again at once when its knock is refused, and after its port refused it three times; a router that drops what comes to a closed port, not refuses it, is found to have forgotten the port only at the next bind. The key of the knocks of a server lives twice as long: a server stopped without a word is forgotten then.'));
		choices(o, [ [ '5', _('5 min') ], [ '10', _('10 min') ], [ '15', _('15 min') ], [ '30', _('30 min') ], [ '60', _('1 h') ] ]);
		o.default = '30';
		o = s.taboption('guard', form.ListValue, 'tries', _('Wrong tries'), _('Requests and knocks with a wrong password or key, per address. One more is allowed each minute; past them the address is blocked.'));
		choices(o, [ [ '3', '3' ], [ '5', '5' ], [ '10', '10' ], [ '20', '20' ], [ '50', '50' ] ]);
		o.default = '5';
		o = s.taboption('guard', form.ListValue, 'block', _('Block for'), _('How long a blocked address is ignored.'));
		choices(o, [ [ '60', _('1 min') ], [ '300', _('5 min') ], [ '600', _('10 min') ], [ '3600', _('1 h') ], [ '86400', _('1 day') ] ]);
		o.default = '600';
		o = s.taboption('guard', form.Flag, 'guard', _('Stop password guessing'),
			_('Bots of the internet guess the passwords of Remote Desktop and SSH, each try a short connection. An address that makes too many short connections to a port is blocked at that port. Turn it off only for a service whose connections are short by nature.'));
		o.default = '1';
		o.rmempty = false;
		o = s.taboption('guard', form.ListValue, 'short', _('Short is'), _('A connection that ends sooner counts as a password tried and refused.'));
		choices(o, [ [ '5', _('under 5 s') ], [ '10', _('under 10 s') ], [ '20', _('under 20 s') ], [ '30', _('under 30 s') ], [ '60', _('under 1 min') ], [ '120', _('under 2 min') ] ]);
		o.default = '20';
		o.depends('guard', '1');
		o = s.taboption('guard', form.ListValue, 'guesses', _('Short connections'), _('Allowed per address and port. One more is allowed each 10 minutes; past them the address is blocked at that port.'));
		choices(o, [ [ '3', '3' ], [ '5', '5' ], [ '10', '10' ], [ '20', '20' ] ]);
		o.default = '5';
		o.depends('guard', '1');
		o = s.taboption('guard', form.ListValue, 'connections', _('Connections per address'), _('Connections one address may have through the router at once. One more meets nobody until one of them ends; a connection whose client is gone without closing it counts until the server closes it too. Several people behind one public address - an office, a mobile network - count as one address.'));
		choices(o, [ [ '0', _('any number') ], [ '2', '2' ], [ '4', '4' ], [ '8', '8' ], [ '16', '16' ], [ '32', '32' ], [ '64', '64' ] ]);
		o.default = '0';
		// the details of each setting in its tooltip: the form shows the names and the values
		s.children.forEach(function(v) { if (v.description) { v.tooltip = v.description; v.tooltipicon = 'ⓘ'; v.description = null; } });

		// ── the IP that changes: a router whose IP this one keeps, by a name - its keys made, its line to copy; this router's own IP
		// that changes, by the line of a router of a fixed IP pasted. Each saved and applied at once ──
		this.addressSaid = E('div');
		var newName = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'placeholder': _('its name, such as dacha'), 'style': 'width:14em' });
		var addKept = E('button', { 'class': 'btn cbi-button-add', 'click': function() {
			var name = newName.value.trim();
			if (!/^[A-Za-z0-9_-]+$/.test(name))
				return said(page.addressSaid, _('A name of letters, digits, - and _, such as dacha.'));
			if (uci.sections('adhoc-relay', 'record').some(function(x) { return x.name == name; }))
				return said(page.addressSaid, _('A router named %s is there already.').format(name));
			if (!page.address())
				return said(page.addressSaid, _('The IP of this router is not found, so its line would have none. Set a DNS name in Settings first.'));
			var id = uci.add('adhoc-relay', 'record');
			uci.set('adhoc-relay', id, 'name', name);
			uci.set('adhoc-relay', id, 'write', newPassword());
			uci.set('adhoc-relay', id, 'read', [ newPassword() ]);
			return page.apply(page.addressSaid);
		} }, _('Add'));
		var pasted = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'placeholder': _('the connection line of the relay to notify'), 'style': 'width:100%; max-width:34em' });
		var addReport = E('button', { 'class': 'btn cbi-button-add', 'click': function() {
			var r = parseTo(pasted.value);
			if (!r)
				return said(page.addressSaid, _('This is not the line of a router that keeps IPs. Paste it whole, as that router copies it.'));
			if (uci.sections('adhoc-relay', 'report').some(function(x) { var y = parseTo(x.to); return y && y.write == r.write; }))
				return said(page.addressSaid, _('This line is added already.'));
			var id = uci.add('adhoc-relay', 'report');
			uci.set('adhoc-relay', id, 'to', toLine(r));
			return page.apply(page.addressSaid);
		} }, _('Add'));

		// ── what happens now, under the ports: the addresses blocked - only while there are any -, what came in the last 10 minutes,
		// folded: for finding out why something does not work ──
		this.blocked = table([ _('Address'), _('Why'), _('Blocked for'), '' ]);
		this.blockedCount = E('span');
		this.blockedBox = E('div', { 'style': 'display:none' });
		this.tries = table([ _('When'), _('From'), _('Port'), _('What') ]);
		this.triesNote = E('span');
		// opened: its rows are asked for now - folded, the router does not make them
		// Open or folded is remembered while the tab of the browser lives: Turn on applies the settings, the page comes anew after
		// it, and the list it was clicked in is open again
		var kept = function(open) { try { if (open == null) return window.sessionStorage.getItem('adhoc-relay-tries') == '1'; window.sessionStorage.setItem('adhoc-relay-tries', open ? '1' : '0'); } catch (e) {} return false; };
		this.triesBox = E('details', { 'style': 'margin-top:1.2em', 'toggle': function() { kept(page.triesBox.open); if (page.triesBox.open && page.fresh) page.fresh(); else page.showTries(); } }, [
			E('summary', { 'style': 'cursor:pointer; font-weight:bold' }, [ _('The last 10 minutes'), tip(_('Requests for a port, knocks, connections to the ports held, IPs reported and looked up: for finding out why something does not work. Scans of the internet at ports nobody holds are left out. Off unless turned on here: while on, the router notes each of them - one more write at every knock, request and connection. Turn it off when done.')) ]),
			E('div', { 'class': 'cbi-section-descr' }, this.triesNote),
			this.tries
		]);
		if (kept()) this.triesBox.open = true;
		this.keptTable = table([ _('Relay'), _('Its IP now'), _('Reported'), '' ]);
		this.reportsTable = table([ _('Relay'), _('Servers can look it up'), _('Last answer'), _('It sees this router as'), '' ]);

		// a heading, its details in a tooltip, its buttons on the right
		function head(title, right, help) {
			return E('div', { 'style': 'display:flex; flex-wrap:wrap; gap:.5em; justify-content:space-between; align-items:center; margin:1.2em 0 .3em' }, [
				E('h4', { 'style': 'margin:0' }, [].concat(title, help ? tip(help) : '')), E('span', {}, right)
			]);
		}

		return Promise.all([ mMain.render() ]).then(function(maps) {
			// the forms loaded the settings into uci: what depends on them now
			page.update(st);
			// What the router does now, each 10 s - not while the page is out of sight: every asking is work for the router. The
			// meetings - the router reads every connection it knows for them - and the ports one by one - with thousands of
			// servers, thousands of lines of its sets - only on the tab Ports, where they show; the last 10
			// minutes only while that list is open. On the other tabs the count of connections at the top is the last one seen. An
			// answer that did not come - a timeout, rpcd started again - draws nothing: the page keeps what it showed, and does
			// not say Not running of a router that runs. An answer that took long - thousands of servers, a slow router - is asked
			// for again only after twice that time: the page takes a third of the router at most
			var fresh = page.fresh = function() {
				var ports = page.shownTab() == 'ports', start = Date.now();
				return L.resolveDefault(callStatus(ports, ports && page.triesBox.open), null).then(function(now) {
					page.restUntil = Date.now() + 2 * (Date.now() - start);
					if (now && now.running != null) page.update(now);
				});
			};
			poll.add(function() { return document.hidden || Date.now() < (page.restUntil || 0) ? Promise.resolve() : fresh(); }, 10);
			document.addEventListener('visibilitychange', function() { if (!document.hidden) fresh(); });

			var tabs = E('div', {}, [
				E('div', { 'data-tab': 'ports', 'data-tab-title': _('Ports') }, [
					head('♻️ ' + _('Any free port: a new one at every start'), page.passwordButtons,
						_('A server asks a port by the password, or by the key of a user, at each start. Copy: the line of a server - it holds the key, give it to the owner of that server alone. New key: the lines copied before open nothing. 🟢 - a client is connected now.')),
					page.givenTable,
					head('⚓ ' + _('Fixed ports'), small('+ ' + _('Add'), function() { page.fixedDialog(null); }, 'add', _('A port of its own for one server, the same at every start')),
						_('A port of its own for one server, the same at every start: its key alone opens it. Click a name to change it. 🟢 - a client is connected now.')),
					page.fixedTable,
					page.portsNote,
					page.portsSaid,
					(dom.content(page.blockedBox, [
						head([ '⛔ ' + _('Blocked addresses'), page.blockedCount ], '', _('Too many wrong passwords or keys block an address at every port; too many short connections to one port - password guessing - block it at that port.')),
						page.blocked
					]), page.blockedBox),
					page.triesBox
				]),
				E('div', { 'data-tab': 'users', 'data-tab-title': _('Users') }, [
					head('🔑 ' + _('Users'), small('+ ' + _('Add a user'), function() { page.userDialog(null); }, 'add'),
						_('A user gets a key of their own, using any free port, a fixed port, or the IP of a record: it works as the password, the key of that port or its read key, until its last day. With a limit, what its meetings carry through this router is counted, and stopped past the limit: more work for the router, each packet of them. Without a limit nothing is counted. Direct only: its traffic can be passed via a direct connection only. Take it away, and it opens nothing; with a limit, its meetings going on end too. Tags group the users: choose by them, and take a group away at once. Click a name to change it.')),
					E('div', { 'style': 'display:flex; flex-wrap:wrap; gap:.5em; align-items:center; margin:.5em 0' }, [
						tagFilter, page.tagAny, page.dropShown
					]),
					page.usersNote,
					page.userTable,
					page.userSaid,
					head(_('The names of the tags'), '', _('A tag is a number of 0-255; a name makes it easier to choose. Up to 8 tags to a user.')),
					page.tagsBox
				]),
				E('div', { 'data-tab': 'address', 'data-tab-title': _('Changing IP') }, [
					head(_('On my public IP change, notify the following relays'), '', _('When the provider changes the public IP of this router now and then, another AdHoc Relay of a fixed IP keeps track of it: this router reports its IP there every 60 s and at once when it changes, the servers look it up there. The ports stay the same. The line to paste: on a router of a fixed IP - Changing IP > Track the public IP of other relays, a name for this one, Add, Copy; on a Linux computer - sudo adhoc-relay record add <name>. Then copy the lines of the servers again, in Ports.')),
					E('div', { 'style': 'display:flex; flex-wrap:wrap; gap:.5em; align-items:center; margin:.5em 0' }, [ pasted, addReport ]),
					page.reportsTable,
					head(_('Track the public IP of other relays'), '', _('This router has a fixed IP: it keeps track of the public IP of relays whose IP changes, for their servers. A name, Add, then Copy its line and paste it on that router. A read key of their own for someone: Users, in place of its IP.')),
					E('div', { 'style': 'display:flex; flex-wrap:wrap; gap:.5em; align-items:center; margin:.5em 0' }, [ newName, addKept ]),
					page.keptTable,
					page.addressSaid
				]),
				E('div', { 'data-tab': 'settings', 'data-tab-title': _('Settings') }, [
					maps[0],
					E('h4', {}, [ _('Uninstall'), tip(_('Removes AdHoc Relay from this router, its settings too. Run the installer again to have it back.')) ]),
					E('button', { 'class': 'btn cbi-button-negative', 'click': uninstall }, _('Uninstall AdHoc Relay'))
				])
			]);
			tabs.childNodes.forEach(function(pane) {
				// back on Ports: the meetings are asked for at once
				pane.addEventListener('cbi-tab-active', function(ev) { page.footer(ev.detail.tab); if (ev.detail.tab == 'ports' && page.tabSeen && page.tabSeen != 'ports') fresh(); page.tabSeen = ev.detail.tab; });
			});
			var root = E('div', {}, [
				E('h2', _('AdHoc Relay')),
				E('div', { 'class': 'cbi-map-descr' }, [ _('Reach a computer behind NAT through this router.'),
					tip(_('As through a forwarded port: the computer - the server - holds a port here; its clients connect to that port. They meet directly when they can; else the router joins the two connections in its kernel, at its full speed.')) ]),
				page.top,
				tabs
			]);
			// the menu of the tabs goes before them: they need a parent for it
			ui.tabs.initTabGroup(tabs.childNodes);
			// the footer comes after the page: hidden or shown once it is there
			window.setTimeout(function() { page.footer(); }, 0);
			return root;
		});
	}
});
