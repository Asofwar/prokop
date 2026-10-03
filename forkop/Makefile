include $(TOPDIR)/rules.mk

PKG_NAME:=forkop

FORKOP_SOURCE_VERSION:=$(or $(FORKOP_PACKAGE_VERSION),$(FORKOP_VERSION))
FORKOP_HAS_RELEASE_VERSION:=$(if $(filter dev,$(FORKOP_SOURCE_VERSION)),,$(FORKOP_SOURCE_VERSION))
FORKOP_COMPILED_VERSION:=$(if $(FORKOP_HAS_RELEASE_VERSION),$(FORKOP_SOURCE_VERSION),$(or $(FORKOP_SOURCE_VERSION),dev))
FORKOP_RELEASE_VERSION_VALID:=$(if $(FORKOP_HAS_RELEASE_VERSION),$(shell printf '%s\n' '$(FORKOP_SOURCE_VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$$' && printf '1'),1)

ifeq ($(FORKOP_RELEASE_VERSION_VALID),)
$(error FORKOP_PACKAGE_VERSION and FORKOP_VERSION must use x.y.z format, or x.y.z-N with a numeric package revision N)
endif

# A release x.y.z-N is version x.y.z, package release N: 1.2.3-4 in the
# ipk and 1.2.3-r4 in the apk, as build.sh's packages carry it.
PKG_VERSION:=$(or $(firstword $(subst -, ,$(FORKOP_HAS_RELEASE_VERSION))),0.0.0)
PKG_RELEASE:=$(word 2,$(subst -, ,$(FORKOP_HAS_RELEASE_VERSION)))

PKG_MAINTAINER:=Asofwar <7397608+Asofwar@users.noreply.github.com>
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/forkop
	SECTION:=net
	CATEGORY:=Network
	DEPENDS:=+ca-bundle +kmod-inet-diag +kmod-tun +curl +ucode +ucode-mod-fs +ucode-mod-uci +conntrack +kmod-nft-tproxy +coreutils-base64 +bind-dig +nftables-json +kmod-nft-nat +ip-full
	CONFLICTS:=https-dns-proxy nextdns luci-app-passwall luci-app-passwall2
	TITLE:=Forkop backend service
	URL:=https://github.com/Asofwar/forkop
	PKGARCH:=all
endef

define Package/forkop/description
	Rule-based Forkop backend with hybrid sing-box + zapret orchestration
endef

define Build/Configure
endef

define Build/Compile
endef

# OpenWrt's default_prerm around it also disables the package's init
# scripts on a removal: /etc/init.d/forkop keeps its autostart, which no
# postinst brings back after a reinstall, as with build.sh's packages. Its
# plain stop stops nothing, on an upgrade and on a removal: package_prerm's
# own stops name their source (/etc/init.d/forkop stop_service), and Forkop
# stays as they left it, as with build.sh's packages, which run no default
# script.
define Package/forkop/prerm
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
forkop_action="$$2"
forkop_version="$$3"
if [ -z "$$forkop_action" ] &&
	{ [ -n "$${APK_SCRIPT}" ] || [ -z "$${PKG_ROOT}" ] || [ "$${PKG_UPGRADE}" != 1 ]; }; then
	forkop_action=remove
fi
case "$$forkop_version" in
	*[!A-Za-z0-9.~+_-]*) forkop_version= ;;
esac
/usr/bin/forkop package_prerm $${forkop_action:+"$$forkop_action"} $${forkop_version:+"$$forkop_version"} >/dev/null 2>&1
exit 0
endef
# The same script as build.sh write_backend_postinst writes (make reads $$
# as $); tests/package_postinst_chain.sh and tests/package_recipe_parity.sh
# compare them. The SDK runs it from OpenWrt's default_postinst, which also
# enables the package's init scripts on a first install and starts them:
# /etc/init.d/forkop leaves both to this script (package_postinst), as with
# build.sh's packages, which run no default_postinst.
define Package/forkop/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
FORKOP_LIB=/usr/lib/forkop ucode -L /usr/lib/forkop /usr/lib/forkop/service/package.uc restore-config &&
	FORKOP_LIB=/usr/lib/forkop ucode -L /usr/lib/forkop /usr/lib/forkop/config/migration.uc migrate
forkop_migrate_status=$$?
FORKOP_PACKAGE_POSTINST=1 /usr/share/forkop/mirror-migration.sh ||
	logger -t forkop "[warn] Package mirror migration failed (status $$?); the package feeds were left unchanged"
/usr/bin/forkop package_postinst
forkop_postinst_status=$$?
[ "$$forkop_migrate_status" -eq 0 ] || exit "$$forkop_migrate_status"
exit "$$forkop_postinst_status"
endef

# apk runs a pre-upgrade script only for a package with Package/preinst
# (include/package-pack.mk): "export PKG_UPGRADE=1" and this text, run as
# "pre-upgrade <new version> <old version>" with the installed
# /usr/bin/forkop. It stops Forkop for the upgrade as build.sh's
# backend-pre-upgrade.sh, and its failure keeps the installed release. The
# same text is the apk's pre-install and the ipk's preinst, run before an
# install or after prerm stopped Forkop for an opkg upgrade: those do nothing.
define Package/forkop/preinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ "$${APK_SCRIPT}" = pre-upgrade ] || exit 0
forkop_version="$$1"
case "$$forkop_version" in
	*[!A-Za-z0-9.~+_-]*) forkop_version= ;;
esac
/usr/bin/forkop package_prerm upgrade $${forkop_version:+"$$forkop_version"} >/dev/null 2>&1
endef

define Package/forkop/conffiles
/etc/config/forkop
endef

# The files of build.sh build_backend_root, with its modes: directories and
# the library 0755 and 0644, the configuration 0600 (it holds secrets), its
# packaged defaults 0644, the commands and init scripts 0755
# (tests/package_recipe_parity.sh compares the two).
define Package/forkop/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/forkop $(1)/etc/init.d/forkop
	$(INSTALL_BIN) ./files/etc/init.d/forkop-torrserver-direct $(1)/etc/init.d/forkop-torrserver-direct
	$(INSTALL_BIN) ./files/etc/init.d/forkop-killswitch $(1)/etc/init.d/forkop-killswitch
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/lib/upgrade/keep.d/forkop-killswitch $(1)/lib/upgrade/keep.d/forkop-killswitch
	$(INSTALL_DIR) $(1)/usr/share/nftables.d/ruleset-post
	$(INSTALL_DATA) ./files/usr/share/nftables.d/ruleset-post/90-forkop-killswitch-loader.nft $(1)/usr/share/nftables.d/ruleset-post/90-forkop-killswitch-loader.nft

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/forkop $(1)/etc/config/forkop

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/forkop $(1)/usr/bin/forkop

	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/forkop-ro $(1)/usr/libexec/forkop-ro

	$(INSTALL_DIR) $(1)/usr/lib/forkop
	$(CP) ./files/usr/lib/. $(1)/usr/lib/forkop/
	find $(1)/usr/lib/forkop -type f -exec chmod 0644 {} +

	$(INSTALL_DIR) $(1)/usr/share/forkop/defaults
	$(INSTALL_DATA) ./files/etc/config/forkop $(1)/usr/share/forkop/defaults/forkop
	$(INSTALL_BIN) ./files/usr/share/forkop/mirror-migration.sh $(1)/usr/share/forkop/mirror-migration.sh

	find $(1) -mindepth 1 -type d -exec chmod 0755 {} +
	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(FORKOP_COMPILED_VERSION)/g' $(1)/usr/lib/forkop/core/constants.uc
endef

$(eval $(call BuildPackage,forkop))
