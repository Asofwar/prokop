include $(TOPDIR)/rules.mk

PKG_NAME:=prokop

PROKOP_SOURCE_VERSION:=$(or $(PROKOP_PACKAGE_VERSION),$(PROKOP_VERSION))
PROKOP_HAS_RELEASE_VERSION:=$(if $(filter dev,$(PROKOP_SOURCE_VERSION)),,$(PROKOP_SOURCE_VERSION))
PROKOP_COMPILED_VERSION:=$(if $(PROKOP_HAS_RELEASE_VERSION),$(PROKOP_SOURCE_VERSION),$(or $(PROKOP_SOURCE_VERSION),dev))
PROKOP_RELEASE_VERSION_VALID:=$(if $(PROKOP_HAS_RELEASE_VERSION),$(shell printf '%s\n' '$(PROKOP_SOURCE_VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$$' && printf '1'),1)

ifeq ($(PROKOP_RELEASE_VERSION_VALID),)
$(error PROKOP_PACKAGE_VERSION and PROKOP_VERSION must use x.y.z format, or x.y.z-N with a numeric package revision N)
endif

# A release x.y.z-N is version x.y.z, package release N: 1.2.3-4 in the
# ipk and 1.2.3-r4 in the apk, as build.sh's packages carry it.
PKG_VERSION:=$(or $(firstword $(subst -, ,$(PROKOP_HAS_RELEASE_VERSION))),0.0.0)
PKG_RELEASE:=$(word 2,$(subst -, ,$(PROKOP_HAS_RELEASE_VERSION)))

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

# OpenWrt's default_prerm around it also disables the package's init
# scripts on a removal: /etc/init.d/prokop keeps its autostart, which no
# postinst brings back after a reinstall, as with build.sh's packages. Its
# plain stop stops nothing, on an upgrade and on a removal: package_prerm's
# own stops name their source (/etc/init.d/prokop stop_service), and Prokop
# stays as they left it, as with build.sh's packages, which run no default
# script.
define Package/prokop/prerm
#!/bin/sh

# OpenWrt never runs this file itself: the ipk's prerm sources it from
# default_prerm, where opkg's "prerm remove" or "prerm upgrade <new
# version>" arrive as $$2 and $$3, and apk appends it to the pre-deinstall
# script, which runs only for a removal. The new version tells whether the
# incoming release can lift the kill-switch. opkg sets PKG_ROOT and
# PKG_UPGRADE (1 for an upgrade, 0 otherwise), apk APK_SCRIPT. A prerm
# without an action (service/package.uc remember_upgrade_state) is taken
# as default_prerm takes it: as build.sh's prerm, this passes none on for
# opkg's upgrade, and package_prerm decides by the service's state; any
# other is a removal, which lifts the kill-switch whose watcher
# default_prerm stops right after this.
[ -n "$${IPKG_INSTROOT}" ] && exit 0
prokop_action="$$2"
prokop_version="$$3"
if [ -z "$$prokop_action" ] &&
	{ [ -n "$${APK_SCRIPT}" ] || [ -z "$${PKG_ROOT}" ] || [ "$${PKG_UPGRADE}" != 1 ]; }; then
	prokop_action=remove
fi
case "$$prokop_version" in
	*[!A-Za-z0-9.~+_-]*) prokop_version= ;;
esac
/usr/bin/prokop package_prerm $${prokop_action:+"$$prokop_action"} $${prokop_version:+"$$prokop_version"} >/dev/null 2>&1
exit 0
endef
# The same script as build.sh write_backend_postinst writes (make reads $$
# as $); tests/package_postinst_chain.sh and tests/package_recipe_parity.sh
# compare them. The SDK runs it from OpenWrt's default_postinst, which also
# enables the package's init scripts on a first install and starts them:
# /etc/init.d/prokop leaves both to this script (package_postinst), as with
# build.sh's packages, which run no default_postinst.
define Package/prokop/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
PROKOP_LIB=/usr/lib/prokop ucode -L /usr/lib/prokop /usr/lib/prokop/service/package.uc restore-config &&
	PROKOP_LIB=/usr/lib/prokop ucode -L /usr/lib/prokop /usr/lib/prokop/config/migration.uc migrate
prokop_migrate_status=$$?
PROKOP_PACKAGE_POSTINST=1 /usr/share/prokop/mirror-migration.sh ||
	logger -t prokop "[warn] Package mirror migration failed (status $$?); the package feeds were left unchanged"
/usr/bin/prokop package_postinst
prokop_postinst_status=$$?
[ "$$prokop_migrate_status" -eq 0 ] || exit "$$prokop_migrate_status"
exit "$$prokop_postinst_status"
endef

# apk runs a pre-upgrade script only for a package with Package/preinst
# (include/package-pack.mk): "export PKG_UPGRADE=1" and this text, run as
# "pre-upgrade <new version> <old version>" with the installed
# /usr/bin/prokop. It stops Prokop for the upgrade as build.sh's
# backend-pre-upgrade.sh, and its failure keeps the installed release. The
# same text is the apk's pre-install and the ipk's preinst, run before an
# install or after prerm stopped Prokop for an opkg upgrade: those do nothing.
define Package/prokop/preinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ "$${APK_SCRIPT}" = pre-upgrade ] || exit 0
prokop_version="$$1"
case "$$prokop_version" in
	*[!A-Za-z0-9.~+_-]*) prokop_version= ;;
esac
/usr/bin/prokop package_prerm upgrade $${prokop_version:+"$$prokop_version"} >/dev/null 2>&1
endef

define Package/prokop/conffiles
/etc/config/prokop
endef

# The files of build.sh build_backend_root, with its modes: directories and
# the library 0755 and 0644, the configuration 0600 (it holds secrets), its
# packaged defaults 0644, the commands and init scripts 0755
# (tests/package_recipe_parity.sh compares the two).
define Package/prokop/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/prokop $(1)/etc/init.d/prokop
	$(INSTALL_BIN) ./files/etc/init.d/prokop-torrserver-direct $(1)/etc/init.d/prokop-torrserver-direct
	$(INSTALL_BIN) ./files/etc/init.d/prokop-killswitch $(1)/etc/init.d/prokop-killswitch
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/lib/upgrade/keep.d/prokop-killswitch $(1)/lib/upgrade/keep.d/prokop-killswitch
	$(INSTALL_DIR) $(1)/usr/share/nftables.d/ruleset-post
	$(INSTALL_DATA) ./files/usr/share/nftables.d/ruleset-post/90-prokop-killswitch-loader.nft $(1)/usr/share/nftables.d/ruleset-post/90-prokop-killswitch-loader.nft

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/prokop $(1)/etc/config/prokop

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/prokop $(1)/usr/bin/prokop

	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/prokop-ro $(1)/usr/libexec/prokop-ro

	$(INSTALL_DIR) $(1)/usr/lib/prokop
	$(CP) ./files/usr/lib/. $(1)/usr/lib/prokop/
	find $(1)/usr/lib/prokop -type f -exec chmod 0644 {} +

	$(INSTALL_DIR) $(1)/usr/share/prokop/defaults
	$(INSTALL_DATA) ./files/etc/config/prokop $(1)/usr/share/prokop/defaults/prokop
	$(INSTALL_BIN) ./files/usr/share/prokop/mirror-migration.sh $(1)/usr/share/prokop/mirror-migration.sh

	find $(1) -mindepth 1 -type d -exec chmod 0755 {} +
	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(PROKOP_COMPILED_VERSION)/g' $(1)/usr/lib/prokop/core/constants.uc
endef

$(eval $(call BuildPackage,prokop))
