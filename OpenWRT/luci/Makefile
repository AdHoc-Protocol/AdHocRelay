# The page of AdHoc Relay in LuCI, for the build system of OpenWrt: put this folder into the LuCI feed as applications/luci-app-adhoc-relay
# and run
#   make package/luci-app-adhoc-relay/compile

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI page of AdHoc Relay: the password, the settings, the connections
LUCI_DEPENDS:=+luci-base +adhoc-relay
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-adhoc-relay
PKG_VERSION:=0.1
PKG_RELEASE:=1

include ../../luci.mk

# call BuildPackage - OpenWrt buildroot signature
