#!/bin/sh
# The check of the release on Linux ( release.yml ), as root: adhoc-relay-linux.sh installs AdHoc Relay, writes every file as it is in
# the folder AdHocRelay, loads the rules and starts `give` - by systemd when there is one, by itself when not; installing again keeps
# the settings; `remove` takes it all away.
#   sh .github/linux-install.sh <adhoc-relay-linux.sh>

set -e
installer=$1
s=$(cd "$(dirname "$0")/.." && pwd)
CONF=/etc/adhoc-relay.conf
bad=0
same() { cmp -s "$s/$1" "$2" || { echo "not as in the folder: $2"; bad=1; }; }
systemd() { command -v systemctl >/dev/null && [ -d /run/systemd/system ]; }
give_runs() {
	if systemd; then
		systemctl is-active --quiet adhoc-relay
	else
		[ -f /run/adhoc-relay.pid ] && kill -0 "$(cat /run/adhoc-relay.pid)" 2>/dev/null
	fi
}

sh "$installer"
same OpenWRT/files/rules /usr/libexec/adhoc-relay/rules
same Linux/give.pl /usr/libexec/adhoc-relay/give.pl
same Linux/adhoc-relay /usr/local/sbin/adhoc-relay
same OpenWRT/files/adhoc-relay.nft /usr/share/adhoc-relay/adhoc-relay.nft
[ -x /usr/libexec/adhoc-relay/rules ] || { echo "not executable: /usr/libexec/adhoc-relay/rules"; bad=1; }
[ -x /usr/local/sbin/adhoc-relay ] || { echo "not executable: /usr/local/sbin/adhoc-relay"; bad=1; }
grep -qE '^PASSWORD=[A-Za-z0-9]{16}$' "$CONF" || { echo "the password made is not 16 characters"; bad=1; }
[ "$(stat -c %a "$CONF")" = 600 ] || { echo "$CONF is not 600"; bad=1; }
! systemd || same Linux/adhoc-relay.service /etc/systemd/system/adhoc-relay.service
sleep 1
nft list table ip adhoc_relay >/dev/null || { echo "the table adhoc_relay is not loaded"; bad=1; }
give_runs || { echo "give does not run"; bad=1; }

# again: an update, the settings and the ports given kept
sed -i 's/^PASSWORD=.*/PASSWORD=Keep1234Keep5678/' "$CONF"
nft add element ip adhoc_relay given { 41234 }
sh "$installer" >/dev/null
grep -qx 'PASSWORD=Keep1234Keep5678' "$CONF" || { echo "installing again lost the password"; bad=1; }
nft get element ip adhoc_relay given { 41234 } >/dev/null 2>&1 || { echo "installing again lost the ports given"; bad=1; }
sleep 1
give_runs || { echo "give does not run after installing again"; bad=1; }

sh "$installer" remove
for f in /usr/libexec/adhoc-relay /usr/share/adhoc-relay "$CONF" /etc/systemd/system/adhoc-relay.service /usr/local/sbin/adhoc-relay; do
	[ ! -e "$f" ] || { echo "remove left $f"; bad=1; }
done
! nft list table ip adhoc_relay >/dev/null 2>&1 || { echo "remove left the table adhoc_relay"; bad=1; }
! pgrep -f /usr/libexec/adhoc-relay/give.pl >/dev/null || { echo "remove left give running"; bad=1; }

[ "$bad" = 0 ] && echo "the installer of one file: installed, updated, removed"
exit "$bad"
