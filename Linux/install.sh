#!/bin/sh
# Installs AdHoc Relay on this Linux computer, from the folder AdHocRelay ( the rules are in ../OpenWRT/files ):
#   sudo sh Linux/install.sh
# or from adhoc-relay-linux.sh, the release of GitHub: this script with the files it installs in it, one file ( ../pack.sh makes it ):
#   sudo sh adhoc-relay-linux.sh
# It needs nftables and perl. A password of 16 characters is made when /etc/adhoc-relay.conf has none, and printed. Without
# systemd the rules are loaded and `give` started once: do it again after each start of the computer, as printed. The command
# `adhoc-relay` shows what happens and changes the settings: `sudo adhoc-relay help`.
# `sudo sh Linux/install.sh remove` takes it all away, the settings too, and `sudo sh adhoc-relay-linux.sh remove` the same.

set -e
here=$(cd "$(dirname "$0")" && pwd)
CONF=/etc/adhoc-relay.conf

# src <file of the folder AdHocRelay>: its text. The installer of one file has its own src, its files in it
[ -n "$packed" ] || src() { cat "$here/../$1"; }
# put <file of the folder AdHocRelay> <its place> [<mode>]: written there at once
put() {
	src "$1" > "$2"
	[ -z "$3" ] || chmod "$3" "$2"
}
# `give` started without systemd
PID=/run/adhoc-relay.pid

systemd() { command -v systemctl >/dev/null && [ -d /run/systemd/system ]; }

give_off() {
	[ -f "$PID" ] && kill "$(cat "$PID")" 2>/dev/null || true
	rm -f "$PID"
}

if [ "$1" = remove ]; then
	if systemd && [ -f /etc/systemd/system/adhoc-relay.service ]; then
		systemctl disable --now adhoc-relay
		rm -f /etc/systemd/system/adhoc-relay.service
		systemctl daemon-reload
	elif [ -x /usr/libexec/adhoc-relay/rules ]; then
		give_off
		/usr/libexec/adhoc-relay/rules unload
	fi
	rm -rf /usr/libexec/adhoc-relay /usr/share/adhoc-relay /run/adhoc-relay /var/lib/adhoc-relay
	rm -f "$CONF" /usr/local/sbin/adhoc-relay
	echo "AdHoc Relay is removed, its settings too"
	exit 0
fi

if ! command -v nft >/dev/null; then
	echo "AdHoc Relay needs nftables: apt install nftables, dnf install nftables, pacman -S nftables" >&2
	exit 1
fi
if ! command -v perl >/dev/null; then
	echo "AdHoc Relay needs perl: apt install perl-base, dnf install perl, pacman -S perl" >&2
	exit 1
fi

mkdir -p /usr/libexec/adhoc-relay /usr/share/adhoc-relay
put OpenWRT/files/rules /usr/libexec/adhoc-relay/rules 755
put Linux/give.pl /usr/libexec/adhoc-relay/give.pl
mkdir -p /usr/local/sbin
put Linux/adhoc-relay /usr/local/sbin/adhoc-relay 755
put OpenWRT/files/adhoc-relay.nft /usr/share/adhoc-relay/adhoc-relay.nft
put OpenWRT/files/version /usr/share/adhoc-relay/version
[ -f "$CONF" ] || put Linux/adhoc-relay.conf "$CONF"
chmod 600 "$CONF"

. "$CONF"
# none yet: one is made
if [ -z "$PASSWORD" ]; then
	PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
	sed -i "s/^PASSWORD=.*/PASSWORD=$PASSWORD/" "$CONF"
	echo "the password of this computer: $PASSWORD"
fi

if systemd; then
	put Linux/adhoc-relay.service /etc/systemd/system/adhoc-relay.service
	systemctl daemon-reload
	systemctl enable adhoc-relay
	# an update: a reload, not a restart - the stop of a restart unloads the table, and the ports given with it. A reload loads the
	# rules keeping the ports given and their addresses, and `give` at SIGHUP starts anew, its new code and the settings
	if systemctl is-active --quiet adhoc-relay; then
		systemctl reload adhoc-relay
	else
		systemctl restart adhoc-relay
	fi
else
	/usr/libexec/adhoc-relay/rules load "$PASSWORD" "$FIRST" "$LAST" "$WAIT" "$TRIES" "$BLOCK" "$GUARD" "$SHORT" "$GUESSES" "$FIXED" "$RECORDS" "$USERS"
	give_off
	nohup perl /usr/libexec/adhoc-relay/give.pl </dev/null >/dev/null 2>&1 &
	echo $! > "$PID"
	echo "no systemd: after each start of the computer run"
	echo "  . $CONF && /usr/libexec/adhoc-relay/rules load \$PASSWORD \$FIRST \$LAST \$WAIT \$TRIES \$BLOCK \$GUARD \$SHORT \$GUESSES \"\$FIXED\" \"\$RECORDS\" \"\$USERS\" && perl /usr/libexec/adhoc-relay/give.pl &"
fi
echo "AdHoc Relay: requests for a port at $FIRST, ports of meeting $((FIRST + 1))-$LAST"
echo "what happens, the lines for the servers, the settings: sudo adhoc-relay; every command: sudo adhoc-relay help"
