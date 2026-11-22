#!/bin/sh
# Installs AdHoc Relay on this router, from the folder this script is in:
#   sh install.sh
# or from adhoc-relay-openwrt.sh, the release of GitHub: this script with the files of the folder in it, one file to copy
# ( ../pack.sh makes it ):
#   sh adhoc-relay-openwrt.sh
# The modules of ucode `give` needs come from the packages of OpenWrt when they are not there: ucode-mod-socket, 60 KiB, the
# sockets; ucode-mod-digest, 40 KiB, the hash of the keys; ucode-mod-math, which snapshots of OpenWrt do not have; kmod-nft-connlimit, 24 KiB, the count of the
# connections of one address, not a must. nftables, fw4 and ucode are there already. A password of 16
# characters is made when /etc/config/adhoc-relay has none, and printed. A router with LuCI gets the page Services > AdHoc Relay
# too, with the button Uninstall. `sh install.sh remove` does the same: every file installed is erased, the settings too.
# Installing again over an installed AdHoc Relay updates it and keeps its settings. The folder, or the file, copied into /tmp, is
# erased at the end: the files are in their places, and the flash keeps them once.

set -e
# the real path: /var of OpenWrt is a link to /tmp
here=$(cd "$(dirname "$0")" && pwd -P)

# src <file of the folder>: its text. The installer of one file has its own src, its files in it, and the path of itself in packed
[ -n "$packed" ] || src() { cat "$here/$1"; }
# put <file of the folder> <its place> [<mode>]: written there, no copy anywhere else - under $root, when it is a tree. Beside its
# place first, then put in it: a script that runs meanwhile, or a flash that fills up, never leaves half a file there. One that
# is there already as it is, is not written again: an update writes to the flash only what changed
root=
put() {
	mkdir -p "$root$(dirname "$2")"
	if [ -f "$root$2" ] && [ "$(src "$1" | md5sum)" = "$(md5sum < "$root$2")" ]; then
		[ -z "$3" ] || chmod "$3" "$root$2"
		return 0
	fi
	src "$1" > "$root$2.new"
	[ -z "$3" ] || chmod "$3" "$root$2.new"
	mv -f "$root$2.new" "$root$2"
}

# Every file in its place, under $root. With `luci`, the page of LuCI too. The list of what to keep through a flash of the firmware
# goes with them: OpenWrt keeps those files, and its backups have them
lay() {
	put files/rules /usr/libexec/adhoc-relay/rules 755
	put files/uninstall /usr/libexec/adhoc-relay/uninstall 755
	put files/needs /usr/libexec/adhoc-relay/needs 755
	put files/give.uc /usr/libexec/adhoc-relay/give.uc
	put files/public.uc /usr/libexec/adhoc-relay/public.uc
	put files/state /usr/libexec/adhoc-relay/state 755
	# the command for a program that sets the relay up from afar: adhoc-relay api get | set
	put files/adhoc-relay /usr/sbin/adhoc-relay 755
	put files/version /usr/share/adhoc-relay/version
	put files/adhoc-relay.nft /usr/share/adhoc-relay/adhoc-relay.nft
	# the settings of a new install: the first start after the archive of the page makes /etc/config/adhoc-relay of it
	put files/adhoc-relay.config /usr/share/adhoc-relay/adhoc-relay.config
	put files/adhoc-relay.init /etc/init.d/adhoc-relay 755
	put files/adhoc-relay.keep /lib/upgrade/keep.d/adhoc-relay
	# the clock set by NTP: the last days of the users are counted anew
	put files/adhoc-relay.ntp /etc/hotplug.d/ntp/30-adhoc-relay
	[ "$1" = luci ] || return 0
	put luci/htdocs/luci-static/resources/view/adhoc-relay.js /www/luci-static/resources/view/adhoc-relay.js
	put luci/root/usr/share/luci/menu.d/luci-app-adhoc-relay.json /usr/share/luci/menu.d/luci-app-adhoc-relay.json
	put luci/root/usr/share/rpcd/acl.d/luci-app-adhoc-relay.json /usr/share/rpcd/acl.d/luci-app-adhoc-relay.json
	put luci/root/usr/libexec/rpcd/adhoc-relay /usr/libexec/rpcd/adhoc-relay 755
}

# `install.sh tree <folder>`: the files under that folder, as they lie on a router, and what the first start finishes - the archive
# the page of LuCI restores is made of it ( ../pack.sh openwrt-web ). Nothing else is done
if [ "$1" = tree ]; then
	root=${2:?install.sh tree <folder>}
	lay luci
	put files/adhoc-relay.defaults /etc/uci-defaults/90-adhoc-relay 755
	# the links `enable` makes: the service starts with the router
	mkdir -p "$root/etc/rc.d"
	ln -sf ../init.d/adhoc-relay "$root/etc/rc.d/S95adhoc-relay"
	ln -sf ../init.d/adhoc-relay "$root/etc/rc.d/K10adhoc-relay"
	exit 0
fi

if [ "$1" = remove ]; then
	# an argument, not the standard input: the package managers it calls read that
	sh -c "$(src files/uninstall)"
	exit 0
fi

# the packages of OpenWrt it needs, as DEPENDS of the Makefile: the modules of ucode, the flowtables ( files/needs )
if ! sh -c "$(src files/needs)" needs install; then
	echo "AdHoc Relay needs the packages $(sh -c "$(src files/needs)" needs), and they did not install: check the internet of the router, and run the installer again" >&2
	exit 1
fi

if [ -d /www/luci-static/resources ]; then lay luci; else lay; fi
[ -f /etc/config/adhoc-relay ] || put files/adhoc-relay.config /etc/config/adhoc-relay
# the password and the keys are in it: for root alone
chmod 600 /etc/config/adhoc-relay

# none yet: one is made
if [ -z "$(uci -q get adhoc-relay.main.password || true)" ]; then
	password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
	uci set adhoc-relay.main.password="$password"
	uci commit adhoc-relay
	echo "the password of this router: $password"
fi

if [ -d /www/luci-static/resources ]; then
	# LuCI and rpcd see the new page
	rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null || true
	/etc/init.d/rpcd reload 2>/dev/null || true
	echo "LuCI: Services > AdHoc Relay"
fi

/etc/init.d/adhoc-relay enable
/etc/init.d/adhoc-relay restart
# settings that name no ports: those the service takes then
first=$(uci -q get adhoc-relay.main.first || true)
last=$(uci -q get adhoc-relay.main.last || true)
echo "AdHoc Relay: requests for a port at ${first:=40000}, ports of meeting $((first + 1))-${last:-49999}"

# the installer in /tmp is not needed any more and takes the memory: the file of one goes; of the folder, its files go, and the
# folder when nothing else is in it
if [ -n "$packed" ]; then
	case "$packed" in
	/tmp/?*)
		[ ! -f "$packed" ] || { rm -f "$packed"; echo "the installer $packed is erased"; }
		;;
	esac
else
	case "$here" in
	/tmp/?*)
		rm -rf "$here/install.sh" "$here/Makefile" "$here/files" "$here/luci"
		if rmdir "$here" 2>/dev/null; then
			echo "the folder $here is erased"
		else
			echo "the files of AdHoc Relay are erased from $here; the rest in it stays"
		fi
		;;
	esac
fi
echo "to remove AdHoc Relay: Uninstall on its page, or /usr/libexec/adhoc-relay/uninstall"
