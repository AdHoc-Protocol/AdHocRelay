# The package of AdHoc Relay for the build system of OpenWrt: put this folder into package/ of the SDK and run
#   make package/adhoc-relay/compile
# Scripts and rules only, the script `give` of ucode too: one package fits every architecture.

include $(TOPDIR)/rules.mk

PKG_NAME:=adhoc-relay
# the release: one file for both systems, the API tells it
PKG_VERSION:=$(shell cat ./files/version)
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/adhoc-relay
  SECTION:=net
  CATEGORY:=Network
  TITLE:=The meeting of two TCP connections in the NAT of the router
  DEPENDS:=+firewall4 +kmod-nft-offload +kmod-nft-connlimit +ucode +ucode-mod-socket +ucode-mod-uci +ucode-mod-math +ucode-mod-fs +ucode-mod-digest
  PKGARCH:=all
endef

define Package/adhoc-relay/description
  Two sides, each behind its NAT, dial the same port of the router; the router sends the SYN of one to the other as if from
  itself - TCP simultaneous open - and carries their connection in the kernel, as a forwarded port. A side asks the router for a
  free port of meeting with a password of 16 characters, and opens it by a knock: one UDP packet with the password; or knocks at a
  fixed port with its key. A router whose address changes writes it into a record of another, which the sides read. Rules of
  nftables, and a script of ucode that hands out the ports and keeps the records.
endef

define Package/adhoc-relay/conffiles
/etc/config/adhoc-relay
endef

define Build/Compile
endef

define Package/adhoc-relay/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/usr/libexec/adhoc-relay $(1)/usr/share/adhoc-relay
	$(INSTALL_CONF) ./files/adhoc-relay.config $(1)/etc/config/adhoc-relay
	$(INSTALL_BIN) ./files/adhoc-relay.init $(1)/etc/init.d/adhoc-relay
	$(INSTALL_BIN) ./files/rules $(1)/usr/libexec/adhoc-relay/rules
	$(INSTALL_BIN) ./files/uninstall $(1)/usr/libexec/adhoc-relay/uninstall
	$(INSTALL_BIN) ./files/needs $(1)/usr/libexec/adhoc-relay/needs
	$(INSTALL_DATA) ./files/give.uc $(1)/usr/libexec/adhoc-relay/give.uc
	$(INSTALL_DATA) ./files/public.uc $(1)/usr/libexec/adhoc-relay/public.uc
	$(INSTALL_BIN) ./files/state $(1)/usr/libexec/adhoc-relay/state
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/adhoc-relay $(1)/usr/sbin/adhoc-relay
	$(INSTALL_DATA) ./files/version $(1)/usr/share/adhoc-relay/version
	$(INSTALL_DATA) ./files/adhoc-relay.nft $(1)/usr/share/adhoc-relay/adhoc-relay.nft
	$(INSTALL_DIR) $(1)/etc/hotplug.d/ntp
	$(INSTALL_DATA) ./files/adhoc-relay.ntp $(1)/etc/hotplug.d/ntp/30-adhoc-relay
endef

$(eval $(call BuildPackage,adhoc-relay))
