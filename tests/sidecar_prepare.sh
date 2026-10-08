#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export PROKOP_LIB="$LIB" WORK
export PROKOP_SIDECAR_DIR="$WORK/providers" PROKOP_UCI_STATE_FILE="$WORK/uci"
mkdir -p "$PROKOP_SIDECAR_DIR"
chmod 0711 "$PROKOP_SIDECAR_DIR"
# Keep native fs operations; only isolate host binaries/account/command probes.
cat >"$WORK/prepare.uc" <<'UC'
let fs = require("fs");
let c = require("experiments.common");
let providers = require("experiments.sidecar_config");
let native_stat = fs.stat;
fs.stat = function(path) {
    if (path == "/usr/bin/xray") return { type: "file" };
    return native_stat(path);
};
providers.uid = () => "12345";
c.capture = function(args) {
    if (args[0] == "/usr/bin/xray") {
        fs.writefile(getenv("WORK") + "/validation-mode", sprintf("%o", native_stat(providers.DIR).mode & 0777));
        if (getenv("FAIL_STAGE") == "validation") return { code: 1, output: "" };
    }
    if (args[0] == "chown" && getenv("FAIL_STAGE") == "permissions") return { code: 1, output: "" };
    return { code: 0, output: "" };
};
return {};
UC
cat >"$PROKOP_UCI_STATE_FILE" <<'UCI'
prokop.manifest=sidecar
prokop.manifest.enabled=1
prokop.manifest.kind=xray
prokop.manifest.port=1083
prokop.manifest.connection_secret={"protocol":"socks","settings":{"servers":[{"address":"example.com","port":443}]}}
UCI
ucode -L "$LIB" -L "$WORK" -l prepare "$LIB/experiments/sidecars.uc" prepare >"$WORK/result.json"
cat >"$WORK/check.uc" <<'UC'
let fs = require("fs");
function check(ok, message) { if (!ok) { warn(message, "\n"); exit(1); } }
let dir = getenv("PROKOP_SIDECAR_DIR");
let manifest = json(fs.readfile(dir + "/manifest.json"));
check(manifest.success && length(manifest.providers) == 1, "Metadata manifest missing");
let provider = manifest.providers[0];
check(provider.path != dir + "/manifest.json", "Provider named manifest collides with metadata path");
let config = json(fs.readfile(provider.path));
check(config.inbounds[0].port == 1083 && config.outbounds[0].protocol == "socks", "Runtime config overwritten by metadata");
check(provider.args[-1] == provider.path, "Runtime argv does not use config path");
check((fs.stat(provider.path).mode & 0777) == 0600, "Secret config must remain private");
check((fs.stat(provider.data).mode & 0777) == 0700, "Provider data must remain private");
check((fs.stat(dir).mode & 0777) == 0711, "Parent must be traversable after successful preparation");
check(fs.readfile(getenv("WORK") + "/validation-mode") == "711", "Parent must remain traversable during successful validation");
print("manifest collision regression passed\n");
UC
ucode -L "$LIB" "$WORK/check.uc"
cp "$PROKOP_SIDECAR_DIR/manifest.json" "$WORK/manifest.before"
cp "$PROKOP_SIDECAR_DIR/manifest.config.json" "$WORK/config.before"
# These assertions need a native Linux filesystem, not DrvFS's synthetic modes.
[[ "$(stat -f -c %T "$WORK")" != drvfs ]] || { printf 'Native Linux filesystem required\n' >&2; exit 1; }
for stage in validation permissions write; do
  export FAIL_STAGE="$stage"
  rm -rf "$PROKOP_SIDECAR_DIR/manifest.config.json.candidate"
  if [[ "$stage" == write ]]; then
    mkdir "$PROKOP_SIDECAR_DIR/manifest.config.json.candidate"
  fi
  if ucode -L "$LIB" -L "$WORK" -l prepare "$LIB/experiments/sidecars.uc" prepare >"$WORK/failed.json"; then
    printf 'Expected %s preparation failure\n' "$stage" >&2; exit 1
  fi
  case "$stage" in
    validation) reason=xray_config_check_failed ;;
    permissions) reason=provider_permissions_failed ;;
    write) reason=provider_config_write_failed ;;
  esac
  ucode -D "expected=$reason" -e 'let fs = require("fs"); let result = json(fs.readfile(getenv("WORK") + "/failed.json")); if (result.success != false || result.reason != expected) exit(1);'
  mode="$(stat -c %a "$PROKOP_SIDECAR_DIR")"
  [[ "$mode" == 711 ]] || { printf 'Failed %s prepare changed active parent mode: %s (expected 711)\n' "$stage" "$mode" >&2; exit 1; }
  cmp "$WORK/manifest.before" "$PROKOP_SIDECAR_DIR/manifest.json"
  cmp "$WORK/config.before" "$PROKOP_SIDECAR_DIR/manifest.config.json"
  if [[ "$stage" != write ]]; then
    [[ "$(<"$WORK/validation-mode")" == 711 ]] || { printf 'Parent lost traversal during validation\n' >&2; exit 1; }
  fi
  printf 'Failed %s prepare preserves active parent/config/manifest\n' "$stage"
done
