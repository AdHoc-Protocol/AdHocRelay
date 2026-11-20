#!/bin/sh
# The check of the release, in OpenWrt booted in Docker as a router ( release.yml ): adhoc-relay-openwrt.sh, copied into /tmp,
# installs AdHoc Relay with its page of LuCI, writes every file as it is in the folder OpenWRT and erases itself; installing again
# keeps the settings; `remove` takes it all away. The repository is at /src.

set -e
# the LAN of the router is the network of Docker: the first boot made it a bridge of its own
uci set network.lan.device=eth0
uci set network.lan.ipaddr=10.97.0.2/24
uci set network.lan.gateway=10.97.0.1
uci -q delete network.@device[0] || true
uci commit network
/etc/init.d/network reload
sleep 3
echo 'nameserver 1.1.1.1' > /tmp/resolv.conf.d/resolv.conf.auto
if command -v apk >/dev/null; then
	apk update >/dev/null && apk add luci >/dev/null
else
	opkg update >/dev/null && opkg install luci >/dev/null
fi

s=/src/OpenWRT
bad=0
same() { cmp -s "$s/$1" "$2" || { echo "not as in the folder: $2"; bad=1; }; }
runs() { [ -x "$1" ] || { echo "not executable: $1"; bad=1; }; }

cp /src/adhoc-relay-openwrt.sh /tmp/
sh /tmp/adhoc-relay-openwrt.sh
[ ! -e /tmp/adhoc-relay-openwrt.sh ] || { echo "the installer is not erased"; bad=1; }
same files/rules /usr/libexec/adhoc-relay/rules
same files/uninstall /usr/libexec/adhoc-relay/uninstall
same files/give.uc /usr/libexec/adhoc-relay/give.uc
same files/needs /usr/libexec/adhoc-relay/needs
same files/adhoc-relay.keep /lib/upgrade/keep.d/adhoc-relay
same files/public.uc /usr/libexec/adhoc-relay/public.uc
same files/adhoc-relay.nft /usr/share/adhoc-relay/adhoc-relay.nft
same files/adhoc-relay.init /etc/init.d/adhoc-relay
same luci/htdocs/luci-static/resources/view/adhoc-relay.js /www/luci-static/resources/view/adhoc-relay.js
same luci/root/usr/share/luci/menu.d/luci-app-adhoc-relay.json /usr/share/luci/menu.d/luci-app-adhoc-relay.json
same luci/root/usr/share/rpcd/acl.d/luci-app-adhoc-relay.json /usr/share/rpcd/acl.d/luci-app-adhoc-relay.json
same luci/root/usr/libexec/rpcd/adhoc-relay /usr/libexec/rpcd/adhoc-relay
runs /usr/libexec/adhoc-relay/rules
runs /usr/libexec/adhoc-relay/uninstall
runs /usr/libexec/adhoc-relay/needs
runs /etc/init.d/adhoc-relay
runs /usr/libexec/rpcd/adhoc-relay
nft list table ip adhoc_relay >/dev/null || { echo "the table adhoc_relay is not loaded"; bad=1; }
ubus call service list '{"name":"adhoc-relay"}' | grep -q '"running": true' || { echo "give does not run"; bad=1; }

# again: an update, the settings and the ports given kept
uci set adhoc-relay.main.password=Keep1234Keep5678
uci commit adhoc-relay
nft add element ip adhoc_relay given { 41234 }
cp /src/adhoc-relay-openwrt.sh /tmp/
sh /tmp/adhoc-relay-openwrt.sh >/dev/null
[ "$(uci -q get adhoc-relay.main.password)" = Keep1234Keep5678 ] || { echo "installing again lost the password"; bad=1; }
nft get element ip adhoc_relay given { 41234 } >/dev/null 2>&1 || { echo "installing again lost the ports given"; bad=1; }

cp /src/adhoc-relay-openwrt.sh /tmp/
sh /tmp/adhoc-relay-openwrt.sh remove
for f in /usr/libexec/adhoc-relay /usr/share/adhoc-relay /etc/init.d/adhoc-relay /etc/config/adhoc-relay \
	/www/luci-static/resources/view/adhoc-relay.js /usr/libexec/rpcd/adhoc-relay; do
	[ ! -e "$f" ] || { echo "remove left $f"; bad=1; }
done
! nft list table ip adhoc_relay >/dev/null 2>&1 || { echo "remove left the table adhoc_relay"; bad=1; }

[ "$bad" = 0 ] && echo "the installer of one file: installed, updated, removed"
exit "$bad"
