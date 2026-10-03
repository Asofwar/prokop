#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_MAKEFILE="$ROOT_DIR/prokop/Makefile"
PROKOP_CONFIG="$ROOT_DIR/prokop/files/etc/config/prokop"
BUILD_SCRIPT="$ROOT_DIR/build.sh"
BUILD_WORKFLOW="$ROOT_DIR/.github/workflows/build.yml"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_file() {
  local file="$1"

  [ -r "$file" ] || fail "required file is missing: $file"
}

require_make_dep() {
  local package="$1"

  grep -Eq "DEPENDS:=.*(^|[[:space:]])\\+$package([[:space:]]|$)" "$PROKOP_MAKEFILE" ||
    fail "prokop/Makefile DEPENDS is missing +$package"
}

require_build_dep() {
  local variable="$1"
  local package="$2"

  grep -Eq "^${variable}=.*(^|[[:space:],])${package}([[:space:],\"]|$)" "$BUILD_SCRIPT" ||
    fail "build.sh ${variable} is missing $package"
}

require_package_dependency() {
  local package="$1"

  require_make_dep "$package"
  require_build_dep "BACKEND_DEPENDS_IPK" "$package"
  require_build_dep "BACKEND_DEPENDS_APK" "$package"
}

require_file "$PROKOP_MAKEFILE"
require_file "$PROKOP_CONFIG"
require_file "$BUILD_SCRIPT"
require_file "$BUILD_WORKFLOW"
require_file "$PROKOP_LIB"

grep -Fq 'PKGARCH:=all' "$PROKOP_MAKEFILE" ||
  fail "Prokop IPK package must remain architecture-independent"
grep -Fq 'LUCI_PKGARCH:=all' "$ROOT_DIR/luci-app-prokop/Makefile" ||
  fail "Prokop LuCI IPK package must remain architecture-independent"
[ "$(grep -Fc 'Architecture: all' "$BUILD_SCRIPT")" -ge 3 ] ||
  fail "manually built IPK packages must remain Architecture: all"
grep -Fq 'arch:noarch' "$BUILD_SCRIPT" ||
  fail "manually built APK packages must remain noarch"
while IFS= read -r -d '' payload_file; do
  if file -b "$payload_file" | grep -Fq 'ELF'; then
    fail "architecture-specific ELF payload is not allowed: $payload_file"
  fi
done < <(find "$ROOT_DIR/prokop/files" "$ROOT_DIR/luci-app-prokop/root" "$ROOT_DIR/luci-app-prokop/htdocs" -type f -print0)

bash "$BUILD_SCRIPT" --help >/dev/null ||
  fail "build.sh must provide command-line usage"
if bash "$BUILD_SCRIPT" 1.2 >/dev/null 2>&1; then
  fail "build.sh must reject invalid release versions before building"
fi
if grep -Eq 'WSL_|WINDOWS_ARTIFACTS_DIR|SOURCE_ROOT_DIR|\.wsl-build|apt-get|sudo' "$BUILD_SCRIPT"; then
  fail "build.sh must remain a portable unprivileged Linux build entrypoint"
fi
grep -Fq 'SDK_DIR="${SDK_DIR:-$SDK_CACHE_DIR/extracted}"' "$BUILD_SCRIPT" ||
  fail "build.sh must reuse the prepared SDK cache independently of BUILD_DIR"
grep -Fq 'flock -n 9' "$BUILD_SCRIPT" ||
  fail "build.sh must reject concurrent package builds"
grep -Fq '[[ ! -f "$luci_src_dir/po2lmo.c" ]]' "$BUILD_SCRIPT" ||
  fail "build.sh must recover from an interrupted LuCI feed checkout"
[ "$(grep -Fc 'fakeroot sh -c' "$BUILD_SCRIPT")" -eq 1 ] ||
  fail "build.sh must use fakeroot for IPK ownership"
[ "$(grep -Fc 'unshare -r sh -c' "$BUILD_SCRIPT")" -eq 1 ] ||
  fail "build.sh must use a user namespace for APK ownership"
grep -Fq 'sudo apt-get install -y' "$BUILD_WORKFLOW" ||
  fail "build workflow must own host dependency installation"
grep -Fq 'sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0' "$BUILD_WORKFLOW" ||
  fail "Ubuntu 24.04 build workflow must allow unprivileged user namespaces"
grep -Fq './build.sh "$VERSION"' "$BUILD_WORKFLOW" ||
  fail "build workflow must invoke the public build entrypoint"
grep -Fq "replace('\\\\n', '\\n')" "$BUILD_WORKFLOW" ||
  fail "build workflow must normalize escaped release-note line breaks"
grep -Fq 'body: ${{ needs.preparation.outputs.release_notes }}' "$BUILD_WORKFLOW" ||
  fail "release action must receive normalized Markdown notes"

for conflict in https-dns-proxy nextdns luci-app-passwall luci-app-passwall2; do
  grep -E 'CONFLICTS:=' "$PROKOP_MAKEFILE" | grep -Fq "$conflict" ||
    fail "prokop/Makefile conflicts are missing $conflict"
  grep -E '^BACKEND_CONFLICTS_IPK=' "$BUILD_SCRIPT" | grep -Fq "$conflict" ||
    fail "manual IPK conflicts are missing $conflict"
  grep -E '^BACKEND_DEPENDS_APK=' "$BUILD_SCRIPT" | grep -Fq "!$conflict" ||
    fail "manual APK conflicts are missing $conflict"
done

if grep -Fq 'coreutils-sort' "$PROKOP_MAKEFILE" "$BUILD_SCRIPT"; then
  fail "unused coreutils-sort runtime dependency must not be packaged"
fi

require_package_dependency "nftables-json"
if grep -Eq '(^|[[:space:],+])nftables([[:space:],]|$)' "$PROKOP_MAKEFILE" "$BUILD_SCRIPT"; then
  fail "Prokop must depend on the concrete nftables-json provider, not the nftables virtual package"
fi
grep -Fq "command_exists(\"nft\")" "$ROOT_DIR/prokop/files/usr/lib/config/validator.uc" ||
  fail "runtime validation must reject a missing nft executable before applying rules"

grep -Fq "must use x.y.z format" "$PROKOP_MAKEFILE" ||
  fail "prokop/Makefile must enforce the three-part release version contract"
apk_version_expression="$(sed -n '/^APK_INTERNAL_VERSION=/p' "$BUILD_SCRIPT")"
for release_version in 1.0.6 1.0.6-2; do
  actual_version="$(RELEASE_VERSION="$release_version" bash -c "$apk_version_expression; printf '%s' \"\$APK_INTERNAL_VERSION\"")"
  expected_version="$release_version"
  [ "$release_version" != 1.0.6-2 ] || expected_version=1.0.6-r2
  [ "$actual_version" = "$expected_version" ] ||
    fail "APK version normalization: expected $expected_version, got $actual_version"
done
grep -Fq "option component_update_check_enabled '1'" "$PROKOP_CONFIG" ||
  fail "new installations must enable component update checks by default"
grep -Fq "option config_version '1.0.5'" "$PROKOP_CONFIG" ||
  fail "new installations must start at the current configuration schema version"
grep -Fq "list applied_migrations 'interface_sections'" "$PROKOP_CONFIG" ||
  fail "new installations must mark the interface section migration as applied"
grep -Fq "list applied_migrations 'enable_component_checks'" "$PROKOP_CONFIG" ||
  fail "new installations must mark the component check migration as applied"
grep -Fq "list applied_migrations 'http_connection_urls'" "$PROKOP_CONFIG" ||
  fail "new installations must mark the HTTP connection URL migration as applied"
grep -Fq "list applied_migrations 'flintnet_urltest_default'" "$PROKOP_CONFIG" ||
  fail "new installations must mark the Flintnet URLTest migration as applied"
grep -Fq "list applied_migrations 'retired_secondary_rulesets'" "$PROKOP_CONFIG" ||
  fail "new installations must mark the retired secondary rule set migration as applied"
grep -Fq "list applied_migrations 'retired_secondary_rulesets_v2'" "$PROKOP_CONFIG" ||
  fail "new installations must mark the updated retired secondary rule set migration as applied"
grep -Fq "list applied_migrations 'secondary_rulesets_mirror_v1'" "$PROKOP_CONFIG" ||
  fail "new installations must mark the secondary rule set mirror migration as applied"
grep -Fq "list applied_migrations 'own_dependency_mirror_v1'" "$PROKOP_CONFIG" ||
  fail "new installations must mark the own dependency mirror migration as applied"
grep -Fq "list applied_migrations 'fork_mirror_opt_in_v1'" "$PROKOP_CONFIG" ||
  fail "new installations must mark the mirror opt-in migration as applied"
grep -Eq "^[[:space:]]+option mirror_base_url ''$" "$PROKOP_CONFIG" ||
  fail "new installations must ship the dependency mirror disabled"
if grep -Eq 'infotechtg|51343' "$PROKOP_CONFIG"; then
  fail "the shipped configuration must not name a former upstream mirror"
fi
fork_identity='Asofwar <7397608+Asofwar@users.noreply.github.com>'
grep -Fxq "MAINTAINER=\"$fork_identity\"" "$BUILD_SCRIPT" ||
  fail "manually built packages must name the fork maintainer"
grep -Fxq 'PROJECT_URL="https://github.com/Asofwar/prokop"' "$BUILD_SCRIPT" ||
  fail "manually built packages must link the fork project"
grep -Fxq "PKG_MAINTAINER:=$fork_identity" "$PROKOP_MAKEFILE" ||
  fail "prokop/Makefile must name the fork maintainer"
grep -Fq 'URL:=https://github.com/Asofwar/prokop' "$PROKOP_MAKEFILE" ||
  fail "prokop/Makefile must link the fork project"
grep -Fxq "LUCI_MAINTAINER:=$fork_identity" "$ROOT_DIR/luci-app-prokop/Makefile" ||
  fail "luci-app-prokop/Makefile must name the fork maintainer"
if grep -Fq 'slayer326' "$BUILD_SCRIPT" "$PROKOP_MAKEFILE" "$ROOT_DIR/luci-app-prokop/Makefile"; then
  fail "package metadata must not name the upstream maintainer"
fi
# The mirror step is best effort: tests/fork_mirror_postinst.sh runs the chains.
if grep -Eq 'mirror-migration\.sh (\|\| exit|&&)' "$PROKOP_MAKEFILE" "$BUILD_SCRIPT"; then
  fail "a mirror reconciliation failure must not skip package_postinst"
fi
grep -Fq '/usr/lib/prokop/config/migration.uc migrate' "$PROKOP_MAKEFILE" ||
  fail "OpenWrt package postinst must run configuration migrations"
grep -Fq 'PROKOP_PACKAGE_POSTINST=1 /usr/share/prokop/mirror-migration.sh' "$PROKOP_MAKEFILE" ||
  fail "OpenWrt package postinst must prevent nested package-manager updates during mirror migration"
# The ipk's postinst and the apk's post-install and post-upgrade, as
# build.sh writes them (one function since UC-026).
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR:?}"' EXIT
# shellcheck source=tests/helpers/build_recipe.sh
. "$ROOT_DIR/tests/helpers/build_recipe.sh"
build_recipe_scripts "$BUILD_SCRIPT" "$WORK_DIR/scripts" || fail "could not write build.sh's package scripts"
for script in ipk/postinst apk/backend-post-install.sh apk/backend-post-upgrade.sh; do
  grep -Fq '/usr/lib/prokop/config/migration.uc migrate' "$WORK_DIR/scripts/$script" ||
    fail "manual package script $script must run configuration migrations after install and upgrade"
  grep -Fq 'PROKOP_PACKAGE_POSTINST=1 /usr/share/prokop/mirror-migration.sh' "$WORK_DIR/scripts/$script" ||
    fail "manual package script $script must prevent nested package-manager updates"
done

if grep -Rqs 'require("uci")' "$PROKOP_LIB"; then
  require_package_dependency "ucode-mod-uci"
fi

if grep -Rqs 'require("fs")' "$PROKOP_LIB"; then
  require_package_dependency "ucode-mod-fs"
fi

if grep -Rqs 'prokop_dnsmasq_failsafe_restore_raw' \
  "$ROOT_DIR/prokop/files/usr/bin" \
  "$ROOT_DIR/prokop/files/usr/lib" \
  "$ROOT_DIR/prokop/files/etc/init.d"; then
  fail "duplicated raw dnsmasq failsafe restore shell owner is present"
fi

printf 'package contract checks passed\n'
