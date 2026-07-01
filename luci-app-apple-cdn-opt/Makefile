include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-apple-cdn-opt
PKG_VERSION:=1.0
PKG_RELEASE:=46

PKG_MAINTAINER:=Antigravity AI
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for Apple CDN Optimizer
  DEPENDS:=+curl +dnsmasq
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  Periodically optimizes Apple TV+ and Apple Music CDN connections by testing and updating hosts.
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(CP) ./root/* $(1)/
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
