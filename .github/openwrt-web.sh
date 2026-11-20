#!/bin/sh
# The check of the release of adhoc-relay-openwrt.tar.gz, the archive the page of LuCI restores ( release.yml ): OpenWrt booted in
# Docker as a router, its LAN the network of Docker; the archive restored as System > Backup / Flash Firmware > Restore backup does
# it - tar -tzf, sysupgrade --restore-backup, a reboot -; the first start makes the settings and a password, the module of ucode
# comes by itself, the relay serves. Restored again, an update: the settings are kept. A flash of the firmware keeps the files;
# Uninstall takes it all away. Run on the runner, beside Docker:
#   sh .github/openwrt-web.sh <image of OpenWrt> adhoc-relay-openwrt.tar.gz

set -e
image=$1 archive=$2
bad=0
on() { docker exec web sh -c "$1"; }
fail() { echo "$1"; bad=1; }
restore() {
	# /tmp of a booted OpenWrt is a tmpfs: docker cp would put the file under it, unseen
	docker cp "$archive" web:/root/backup.tar.gz
	on 'mv /root/backup.tar.gz /tmp/backup.tar.gz && tar -tzf /tmp/backup.tar.gz | grep -q etc/init.d/adhoc-relay && sysupgrade --restore-backup /tmp/backup.tar.gz' >/dev/null ||
		fail "the archive does not restore"
	docker restart -t 5 web >/dev/null
	sleep 8
}
serving() {
	i=0
	while [ $i -lt 60 ]; do
		on 'nft list table ip adhoc_relay >/dev/null 2>&1 && pgrep -f [a]dhoc-relay/give.uc >/dev/null' && return 0
		i=$((i + 1))
		sleep 2
	done
	return 1
}

docker network create --subnet 10.96.0.0/24 webnet >/dev/null
docker run -d --name web --network webnet --ip 10.96.0.2 --cap-add NET_ADMIN --cap-add SYS_ADMIN --sysctl net.ipv4.ip_forward=1 \
	"$image" /sbin/init >/dev/null
sleep 8
on 'uci set network.lan.device=eth0; uci set network.lan.ipaddr=10.96.0.2/24; uci set network.lan.gateway=10.96.0.1;
	uci add_list network.lan.dns=1.1.1.1; uci -q delete network.@device[0]; uci commit network; /etc/init.d/network reload; sleep 3;
	if command -v apk >/dev/null; then apk update >/dev/null && apk add luci >/dev/null; else opkg update >/dev/null && opkg install luci >/dev/null; fi'

restore
[ -n "$(on 'uci -q get adhoc-relay.main.password')" ] || fail "the first start made no password"
on '[ ! -e /etc/uci-defaults/90-adhoc-relay ]' || fail "the first start did not end"
serving || fail "the relay does not serve: $(on 'logread -e adhoc-relay | tail -5')"

password=$(on 'uci -q get adhoc-relay.main.password')
on 'uci set adhoc-relay.main.wait=77; uci commit adhoc-relay'
restore
[ "$(on 'uci -q get adhoc-relay.main.password')" = "$password" ] && [ "$(on 'uci -q get adhoc-relay.main.wait')" = 77 ] ||
	fail "restoring again lost the settings"
serving || fail "the relay does not serve after the update"

on 'sysupgrade -l' | grep -q /usr/libexec/adhoc-relay/give.uc || fail "a flash of the firmware would not keep the files"
on /usr/libexec/adhoc-relay/uninstall >/dev/null
[ -z "$(on 'ls /etc/init.d/adhoc-relay /etc/rc.d/*adhoc-relay /lib/upgrade/keep.d/adhoc-relay /usr/libexec/adhoc-relay 2>/dev/null')" ] ||
	fail "Uninstall left files"

docker rm -f web >/dev/null
docker network rm webnet >/dev/null
[ $bad = 0 ] && echo "installed by the page of LuCI: ok"
exit $bad
