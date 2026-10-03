#!/usr/bin/env bash
# Forkop was renamed to Prokop. Shipped code may still spell "forkop" only
# where the old name is the point:
#   - names of upstream projects and of the upstream mirror protocol, which
#     Prokop shares and must not rename (GLOBAL_PATTERNS below);
#   - names a Forkop installation left on a router, kept in one place per
#     language: prokop/files/usr/lib/core/legacy_forkop.uc (ucode, imported as
#     core.legacy_forkop), fe-app-prokop/src/prokop/helpers/legacyStorage.ts
#     (browser storage) and one "# Legacy Forkop names" block per shell script;
#   - the few file-specific cases in FILE_PATTERNS, each with its reason;
#   - whole-line comments (#, //, /* and * continuation lines), which explain
#     the legacy handling next to the code that does it. A trailing comment on
#     a code line is not exempt.
# Anything else is a missed rename. Frontend catalogs and views must not show
# the old "Forkop X" brand at all.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SCOPE=(prokop luci-app-prokop fe-app-prokop/src install.sh build.sh ops .github)

# Whole files that exist to hold legacy names.
LEGACY_MODULES=(
  prokop/files/usr/lib/core/legacy_forkop.uc
  fe-app-prokop/src/prokop/helpers/legacyStorage.ts
  fe-app-prokop/src/prokop/helpers/tests/legacyStorage.test.ts
)

# Lower-case extended regular expressions, removed from a lower-cased line
# before it is checked; they apply to every scanned file.
GLOBAL_PATTERNS='(slayer326|ushan0v)/forkop
b4geoip-forkop
/forkop/(lists|sing-box-extended|updates|mirror)
public/forkop
forkop-platforms\.tsv
forkop-apk\.pem
forkop\.list
forkop-mirror\.pem
pre-forkop-mirror
forkop(vpn)?[-_]?(vpn[-_])?guard
forkop/vpn-guard
upstream forkop
legacy[-_ ]?forkop
migrating-from-forkop'

# file<TAB>pattern: allowed only in that file.
#   main.js: browser storage keys bundled from legacyStorage.ts.
#   constants.uc: zapret runtime directory older Forkop builds used; Prokop
#     still cleans it up (ZAPRET_LEGACY_RUNTIME_BASE_DIR).
#   ops READMEs: the old repository/channel name and the host-side names a
#     mirror operator renames when upgrading a pre-rename mirror host.
FILE_PATTERNS="$(cat <<'EOF'
luci-app-prokop/htdocs/luci-static/resources/view/prokop/main.js	forkop\.(monitoring\.preferences|connectivity\.targets|diagnostic\.lastrun)
prokop/files/usr/lib/core/constants.uc	/var/run/forkop/zapret-runtime
ops/mirror/README.md	^\|.*
ops/mirror/README.md	<mirror>/forkop/
ops/mirror/README.md	upstream `forkop` names
ops/mirror/README.md	from `forkop` to `prokop`
ops/mirror/README.md	asofwar/forkop
ops/mirror/README.md	renamed forkop
prokop/files/usr/lib/components/action.uc	zapret_manager_forkop_marker
ops/hosting/README.md	asofwar\.github\.io/forkop
ops/hosting/README.md	asofwar/forkop
ops/hosting/README.md	репозиторий `forkop`
ops/hosting/README.md	с forkop
EOF
)"

# Prints "path:line: text" for every unexplained "forkop" in $2 (relative to $1).
scan_file() {
  local root="$1"
  local rel="$2"
  local file_patterns explicit_end=0

  file_patterns="$(printf '%s\n' "$FILE_PATTERNS" | awk -F '\t' -v rel="$rel" '$1 == rel { print $2 }')"
  grep -q '^[[:space:]]*# End of legacy Forkop names' "$root/$rel" && explicit_end=1

  GLOBAL="$GLOBAL_PATTERNS" LOCAL="$file_patterns" awk -v rel="$rel" -v explicit_end="$explicit_end" '
    BEGIN {
      ng = split(ENVIRON["GLOBAL"], global_re, "\n")
      nl = ENVIRON["LOCAL"] == "" ? 0 : split(ENVIRON["LOCAL"], local_re, "\n")
      blocks = 0
      in_block = 0
    }
    /^[ \t]*# Legacy Forkop names/ {
      blocks++
      in_block = 1
      next
    }
    in_block {
      if (explicit_end && $0 ~ /^[ \t]*# End of legacy Forkop names/) { in_block = 0; next }
      if (!explicit_end && $0 ~ /^[ \t]*$/) { in_block = 0; next }
      next
    }
    {
      line = tolower($0)
      if (index(line, "forkop") == 0) next
      if ($0 ~ /^[ \t]*(\/\/|\/\*|\*([ \t]|$)|#([^!]|$))/) next
      if (line ~ /legacy_forkop\./ || line ~ /core\.legacy_forkop/) next
      for (i = 1; i <= ng; i++) gsub(global_re[i], "", line)
      for (i = 1; i <= nl; i++) gsub(local_re[i], "", line)
      if (index(line, "forkop") > 0) printf "%s:%d: %s\n", rel, FNR, $0
    }
    END {
      if (blocks > 1) printf "%s: %d \"# Legacy Forkop names\" blocks, expected at most one\n", rel, blocks
    }
  ' "$root/$rel"
}

is_legacy_module() {
  local rel="$1" module
  for module in "${LEGACY_MODULES[@]}"; do
    [ "$rel" = "$module" ] && return 0
  done
  return 1
}

# The scanner itself must catch a missed rename and accept the allowed forms;
# otherwise an empty report proves nothing.
mkdir -p "$WORK_DIR/self"
cat > "$WORK_DIR/self/missed.sh" <<'EOF'
#!/bin/sh
CONFIG=/etc/config/forkop
echo "Forkop X is running"
case "$name" in
    *forkop*) exit 0 ;;
esac
stop_service # Forkop is gone
EOF
cat > "$WORK_DIR/self/allowed.sh" <<'EOF'
#!/bin/sh
# Legacy Forkop names
LEGACY_FORKOP_CONFIG=/etc/config/forkop
LEGACY_FORKOP_INIT=/etc/init.d/forkop

rm -f /etc/apk/repositories.d/forkop.list /etc/apk/keys/forkop-mirror.pem
cp "$feed.pre-forkop-mirror" "$feed"
url="$MIRROR/forkop/lists/b4geoip-forkop/srs/"
nft delete table inet ForkopVpnGuard
[ -f "$LEGACY_FORKOP_CONFIG" ] && echo "upstream Forkop found"
# Forkop's prerm removes /etc/init.d/sing-box unless the marker is rewritten.
EOF
cat > "$WORK_DIR/self/leak.sh" <<'EOF'
#!/bin/sh
# Legacy Forkop names
LEGACY_FORKOP_INIT=/etc/init.d/forkop

/etc/init.d/forkop stop
# Legacy Forkop names
OTHER=/usr/bin/forkop
EOF
cat > "$WORK_DIR/self/module.uc" <<'EOF'
// Forkop kept its state under /etc/forkop.
/* Forkop's
 * marker */
let legacy_forkop = require("core.legacy_forkop");
let path = legacy_forkop.CONFIG_PATH;
let wrong = "/etc/forkop/state";
EOF

self_missed="$(scan_file "$WORK_DIR/self" missed.sh)"
[ "$(printf '%s\n' "$self_missed" | grep -c .)" -eq 4 ] || {
  printf 'scanner missed a forkop name:\n%s\n' "$self_missed" >&2
  exit 1
}
self_allowed="$(scan_file "$WORK_DIR/self" allowed.sh)"
[ -z "$self_allowed" ] || {
  printf 'scanner rejected an allowed legacy form:\n%s\n' "$self_allowed" >&2
  exit 1
}
self_leak="$(scan_file "$WORK_DIR/self" leak.sh)"
printf '%s\n' "$self_leak" | grep -q '^leak.sh:5: /etc/init.d/forkop stop$' || {
  printf 'scanner let a name outside the legacy block through:\n%s\n' "$self_leak" >&2
  exit 1
}
printf '%s\n' "$self_leak" | grep -q 'blocks, expected at most one' || {
  printf 'scanner accepted two legacy blocks in one file:\n%s\n' "$self_leak" >&2
  exit 1
}
self_module="$(scan_file "$WORK_DIR/self" module.uc)"
[ "$self_module" = 'module.uc:6: let wrong = "/etc/forkop/state";' ] || {
  printf 'scanner mishandled a core.legacy_forkop import:\n%s\n' "$self_module" >&2
  exit 1
}

cd "$ROOT_DIR"
for module in "${LEGACY_MODULES[@]}"; do
  [ -f "$module" ] || { printf 'legacy module %s is missing\n' "$module" >&2; exit 1; }
done

violations="$WORK_DIR/violations"
: > "$violations"
while IFS= read -r rel; do
  rel="${rel#./}"
  is_legacy_module "$rel" && continue
  scan_file "$ROOT_DIR" "$rel" >> "$violations"
done < <(grep -rIil --exclude-dir=node_modules -e forkop -- "${SCOPE[@]}" | sort)

if [ -s "$violations" ]; then
  printf 'Forkop names outside the legacy allowlist (missed rename?):\n' >&2
  cat "$violations" >&2
  exit 1
fi

# The old brand must not reach the LuCI pages or their translations.
brand="$(grep -rIn --exclude-dir=node_modules -e 'Forkop X' -e 'Forkop&nbsp;X' -e 'Forkop\\u00a0X' -- \
  luci-app-prokop fe-app-prokop/src fe-app-prokop/locales || true)"
if [ -n "$brand" ]; then
  printf 'The "Forkop X" brand is still shown in the frontend:\n%s\n' "$brand" >&2
  exit 1
fi
catalog="$(grep -rIn -e 'Forkop' -- luci-app-prokop/po fe-app-prokop/locales || true)"
if [ -n "$catalog" ]; then
  printf 'Translation catalogs still name Forkop:\n%s\n' "$catalog" >&2
  exit 1
fi

printf 'prokop rename completeness: ok\n'
