include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-prokop

PROKOP_SOURCE_VERSION:=$(or $(PROKOP_PACKAGE_VERSION),$(PROKOP_VERSION))
PROKOP_HAS_RELEASE_VERSION:=$(if $(filter dev,$(PROKOP_SOURCE_VERSION)),,$(PROKOP_SOURCE_VERSION))
PROKOP_COMPILED_VERSION:=$(if $(PROKOP_HAS_RELEASE_VERSION),$(PROKOP_SOURCE_VERSION),$(or $(PROKOP_SOURCE_VERSION),dev))
PROKOP_RELEASE_VERSION_VALID:=$(if $(PROKOP_HAS_RELEASE_VERSION),$(shell printf '%s\n' '$(PROKOP_SOURCE_VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' && printf '1'),1)

ifeq ($(PROKOP_RELEASE_VERSION_VALID),)
$(error PROKOP_PACKAGE_VERSION and PROKOP_VERSION must use x.y.z format: the updater, the installer and the release catalog accept nothing else)
endif

PKG_VERSION:=$(or $(firstword $(subst -, ,$(PROKOP_HAS_RELEASE_VERSION))),0.0.0)
PKG_RELEASE:=$(word 2,$(subst -, ,$(PROKOP_HAS_RELEASE_VERSION)))
PKG_PO_VERSION:=$(PKG_VERSION)

LUCI_TITLE:=LuCI Prokop app
LUCI_DEPENDS:=+luci-base +prokop
LUCI_PKGARCH:=all
LUCI_LANG.ru:=Русский (Russian)
LUCI_LANG.en:=English
LUCI_MAINTAINER:=Asofwar <7397608+Asofwar@users.noreply.github.com>
LUCI_DESCRIPTION:=Rule-based Prokop LuCI app with hybrid sing-box + zapret orchestration
# LuCI's jsmin breaks section.js (it takes the regex literal after an arrow,
# `=> /^(full|keyword|regex):/`, for a division and mangles the code after
# it) and drops a space inside a nested template literal of
# notifications.js. build.sh ships the views minified with esbuild instead
# (minify_luci_views); a feed build ships them as they are.
LUCI_MINIFY_JS:=0

PKG_LICENSE:=GPL-2.0-or-later
LUCI_LANGUAGES:=en ru

define Build/Prepare/$(PKG_NAME)
	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(PROKOP_COMPILED_VERSION)/g' $(PKG_BUILD_DIR)/htdocs/luci-static/resources/view/prokop/main.js
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
