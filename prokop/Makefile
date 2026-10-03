include $(TOPDIR)/rules.mk

PKG_NAME:=prokop

PROKOP_SOURCE_VERSION:=$(or $(PROKOP_PACKAGE_VERSION),$(PROKOP_VERSION))
PROKOP_HAS_RELEASE_VERSION:=$(if $(filter dev,$(PROKOP_SOURCE_VERSION)),,$(PROKOP_SOURCE_VERSION))
PROKOP_COMPILED_VERSION:=$(if $(PROKOP_HAS_RELEASE_VERSION),$(PROKOP_SOURCE_VERSION),$(or $(PROKOP_SOURCE_VERSION),dev))
PROKOP_RELEASE_VERSION_VALID:=$(if $(PROKOP_HAS_RELEASE_VERSION),$(shell printf '%s\n' '$(PROKOP_SOURCE_VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' && printf '1'),1)

ifeq ($(PROKOP_RELEASE_VERSION_VALID),)
$(error PROKOP_PACKAGE_VERSION and PROKOP_VERSION must use x.y.z format)
endif

PKG_VERSION:=$(or $(PROKOP_HAS_RELEASE_VERSION),0.0.0)
PKG_RELEASE:=

PKG_MAINTAINER:=Asofwar <7397608+Asofwar@users.noreply.github.com>
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/prokop
	SECTION:=net
	CATEGORY:=Network
	DEPENDS:=+ca-bundle +kmod-inet-diag +kmod-tun +curl +ucode +ucode-mod-fs +ucode-mod-uci +conntrack +kmod-nft-tproxy +coreutils-base64 +bind-dig +nftables-json +kmod-nft-nat +ip-full
	CONFLICTS:=https-dns-proxy nextdns luci-app-passwall luci-app-passwall2
	TITLE:=Prokop backend service
	URL:=https://github.com/Asofwar/prokop
	PKGARCH:=all
endef

define Package/prokop/description
	Rule-based Prokop backend with hybrid sing-box + zapret orchestration
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/prokop/prerm
#!/usr/bin/ucode

if (getenv("IPKG_INSTROOT") == null || getenv("IPKG_INSTROOT") == "")
	system("/usr/bin/prokop package_prerm " + (ARGV[0] || "") + " >/dev/null 2>&1");

exit(0);
endef

define Package/prokop/postinst
#!/bin/sh

[ -n "$${IPKG_INSTROOT}" ] && exit 0
PROKOP_LIB=/usr/lib/prokop ucode -L /usr/lib/prokop /usr/lib/prokop/config/migration.uc migrate || exit $$?
PROKOP_PACKAGE_POSTINST=1 /usr/share/prokop/mirror-migration.sh || echo "Warning: Prokop could not reconcile the package feeds with its mirror setting" >&2
/usr/bin/prokop package_postinst
endef

define Package/prokop/conffiles
/etc/config/prokop
endef

define Package/prokop/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/prokop $(1)/etc/init.d/prokop
	$(INSTALL_BIN) ./files/etc/init.d/prokop-killswitch $(1)/etc/init.d/prokop-killswitch
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/lib/upgrade/keep.d/prokop-killswitch $(1)/lib/upgrade/keep.d/prokop-killswitch

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/prokop $(1)/etc/config/prokop

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/prokop $(1)/usr/bin/prokop

	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/prokop-ro $(1)/usr/libexec/prokop-ro

	$(INSTALL_DIR) $(1)/usr/lib/prokop
	$(CP) ./files/usr/lib/. $(1)/usr/lib/prokop/

	$(INSTALL_DIR) $(1)/usr/share/prokop/defaults
	$(INSTALL_CONF) ./files/etc/config/prokop $(1)/usr/share/prokop/defaults/prokop
	$(INSTALL_BIN) ./files/usr/share/prokop/mirror-migration.sh $(1)/usr/share/prokop/mirror-migration.sh

	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(PROKOP_COMPILED_VERSION)/g' $(1)/usr/lib/prokop/core/constants.uc
endef

$(eval $(call BuildPackage,prokop))
