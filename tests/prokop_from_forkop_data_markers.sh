#!/usr/bin/env bash
# What Forkop installed outside its own package is Prokop's to manage once
# Forkop's package is gone: a managed sing-box service still carrying Forkop's
# marker line counts as managed (components/action.uc, singbox/runtime.uc),
# and Zapret-Manager launchers Forkop wrote are rewritten for the current
# mirror setting by the reconcile step every Prokop package install runs and
# reported as installed by the system information. While Forkop's package is
# still installed (a migration that can still roll back to it), neither is
# touched or claimed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
ACTION_UC="$PROKOP_LIB/components/action.uc"
SINGBOX_UC="$PROKOP_LIB/singbox/runtime.uc"
DIAGNOSTICS_UC="$PROKOP_LIB/diagnostics/runtime.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
# core/legacy_forkop.uc looks for Forkop's package under this root.
FORKOP_ROOT="$WORK_DIR/forkop-root"
export WORK_DIR PROKOP_LIB
export PROKOP_LEGACY_FORKOP_ROOT="$FORKOP_ROOT"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

forkop_installed() {
  mkdir -p "$FORKOP_ROOT/etc/init.d"
  printf '#!/bin/sh /etc/rc.common\n' >"$FORKOP_ROOT/etc/init.d/forkop"
}
forkop_removed() {
  rm -f "$FORKOP_ROOT/etc/init.d/forkop"
}

# The lines Forkop 1.0.x wrote: core/constants.uc SB_MANAGED_SERVICE_MARKER
# and components/action.uc ZAPRET_MANAGER_LAUNCHER_MARKER of the fork.
FORKOP_SING_BOX_MARKER='Forkop managed sing-box service for binary variants'
FORKOP_LAUNCHER_MARKER='# Forkop X Zapret-Manager launcher'

markers="$(ucode -L "$PROKOP_LIB" -e 'let l = require("core.legacy_forkop"); print(l.SING_BOX_MANAGED_MARKER, "|", l.ZAPRET_MANAGER_MARKER, "\n");')"
[ "$markers" = "$FORKOP_SING_BOX_MARKER|$FORKOP_LAUNCHER_MARKER" ] ||
  fail "core/legacy_forkop.uc does not name Forkop's markers: $markers"

# --- managed sing-box service ------------------------------------------------
# service_script MARKER: the service as Forkop or Prokop installed it.
service_script() {
  printf '#!/bin/sh /etc/rc.common\n# %s\n\nUSE_PROCD=1\nSTART=99\nPROG="/usr/bin/sing-box"\n' "$1"
}
mkdir -p "$WORK_DIR/init.d"
service_script "$FORKOP_SING_BOX_MARKER" >"$WORK_DIR/forkop-service"
service_script 'Prokop managed sing-box service for binary variants' >"$WORK_DIR/prokop-service"
printf '#!/bin/sh /etc/rc.common\n# sing-box package service\nUSE_PROCD=1\n' >"$WORK_DIR/package-service"

# The production functions, with /etc/init.d/sing-box pointed at
# $WORK_DIR/init.d/sing-box.
python3 - "$ACTION_UC" "$SINGBOX_UC" "$WORK_DIR" <<'PY'
import re
import sys

action_uc, singbox_uc, work = sys.argv[1:4]


def extract(path, consts, names):
    source = open(path, encoding='utf-8').read()
    parts = []
    for name in consts:
        match = re.search(r'^const ' + name + r' = [^\n]*;$', source, re.M)
        if match is None:
            raise SystemExit(path + ': missing production constant: ' + name)
        parts.append(match.group())
    for name in names:
        match = re.search(r'^function ' + name + r'\([^\n]*\) \{\n.*?^\}', source, re.M | re.S)
        if match is None:
            raise SystemExit(path + ': missing production function: ' + name)
        parts.append(match.group())
    return '\n\n'.join(parts).replace('"/etc/init.d/sing-box"', 'INIT')


prefix = r'''
let fs = require("fs");
let constants = require("core.constants");
let legacy_forkop = require("core.legacy_forkop");
const WORK = getenv("WORK_DIR");
const INIT = WORK + "/init.d/sing-box";
const FORKOP_INIT = getenv("PROKOP_LEGACY_FORKOP_ROOT") + "/etc/init.d/forkop";
'''
suffix = r'''
function check(ok, message) {
    if (!ok) {
        warn("FAIL: " + message + "\n");
        exit(1);
    }
}
function install(name) {
    if (name == null)
        fs.unlink(INIT);
    else
        fs.writefile(INIT, fs.readfile(WORK + "/" + name));
}
fs.unlink(FORKOP_INIT);
install("forkop-service");
check(INSTALLED(), "a service carrying Forkop's marker was not recognised as managed once Forkop is gone");
install("prokop-service");
check(INSTALLED(), "a service carrying Prokop's marker was not recognised as managed");
install("package-service");
check(!INSTALLED(), "the sing-box package's own service was taken for a managed one");
install(null);
check(!INSTALLED(), "a missing service was taken for a managed one");

system([ "mkdir", "-p", replace(FORKOP_INIT, /\/forkop$/, "") ]);
fs.writefile(FORKOP_INIT, "#!/bin/sh /etc/rc.common\n");
install("forkop-service");
check(!INSTALLED(), "Forkop's managed sing-box was claimed while Forkop's package is installed");
install("prokop-service");
check(INSTALLED(), "Prokop's managed sing-box was not recognised next to an installed Forkop");
fs.unlink(FORKOP_INIT);
print("probe: PASS\n");
'''
action = extract(action_uc, ('SB_MANAGED_SERVICE_MARKER', 'SB_LEGACY_MANAGED_SERVICE_MARKER'),
                 ('as_string', 'read_file', 'file_exists', 'managed_sing_box_service_source',
                  'managed_sing_box_service_installed'))
open(work + '/action-probe.uc', 'w', encoding='utf-8').write(
    prefix + action + suffix.replace('INSTALLED()', 'managed_sing_box_service_installed()'))
singbox = extract(singbox_uc, ('SB_MANAGED_SERVICE_MARKER', 'SB_LEGACY_MANAGED_SERVICE_MARKER'),
                  ('as_string', 'managed_service_installed'))
open(work + '/singbox-probe.uc', 'w', encoding='utf-8').write(
    prefix + singbox + suffix.replace('INSTALLED()', 'managed_service_installed()'))
PY

# ucode can report a runtime exception and still exit 0: the verdict is the
# probe's own last line.
for probe in action singbox; do
  result="$(env -u SB_MANAGED_SERVICE_MARKER ucode -L "$PROKOP_LIB" "$WORK_DIR/$probe-probe.uc" 2>&1)" ||
    fail "the $probe managed sing-box probe failed: $result"
  [ "$result" = "probe: PASS" ] || fail "the $probe managed sing-box probe did not finish: $result"
done

# --- Zapret-Manager launchers --------------------------------------------------
BIN="$WORK_DIR/bin"
mkdir -p "$BIN" "$WORK_DIR/expected"
# What Forkop wrote without a mirror and for a mirror, then what Prokop writes.
cat >"$WORK_DIR/expected/forkop-direct" <<EOF
#!/bin/sh
$FORKOP_LAUNCHER_MARKER
exec sh <(wget -q -O - 'https://raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh') "\$@"
EOF
cat >"$WORK_DIR/expected/forkop-mirrored" <<EOF
#!/bin/sh
$FORKOP_LAUNCHER_MARKER
export ZAPRET_MANAGER_MIRROR='https://own-mirror.test'
exec sh <(wget -q -O - 'https://own-mirror.test/zapret-manager/proxy/raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh') "\$@"
EOF
cat >"$WORK_DIR/expected/prokop-direct" <<'EOF'
#!/bin/sh
# Prokop Zapret-Manager launcher
exec sh <(wget -q -O - 'https://raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh') "$@"
EOF
cat >"$WORK_DIR/expected/prokop-mirrored" <<'EOF'
#!/bin/sh
# Prokop Zapret-Manager launcher
export ZAPRET_MANAGER_MIRROR='https://own-mirror.test'
exec sh <(wget -q -O - 'https://own-mirror.test/zapret-manager/proxy/raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh') "$@"
EOF

install_launchers() {
  for name in zms zmsA; do
    cp "$WORK_DIR/expected/$1" "$BIN/$name"
    chmod 0755 "$BIN/$name"
  done
}
assert_launchers() {
  for name in zms zmsA; do
    cmp -s "$WORK_DIR/expected/$1" "$BIN/$name" ||
      fail "$2: $name is not the $1 launcher: $(cat "$BIN/$name" 2>/dev/null || printf 'missing')"
  done
}
# reconcile MIRROR: the step every Prokop package postinst runs.
reconcile() {
  PROKOP_MIRROR_BASE_URL="$1" PROKOP_ZAPRET_MANAGER_BIN_DIR="$BIN" PROKOP_LIB="$PROKOP_LIB" \
    ucode -L "$PROKOP_LIB" "$ACTION_UC" reconcile-zapret-manager-launchers
}

# Prokop's backend is installed next to Forkop before the migration's point of
# no return: Forkop's launchers stay exactly as Forkop wrote them.
forkop_installed
install_launchers forkop-direct
reconcile 'https://own-mirror.test/' >/dev/null || fail "reconciling next to an installed Forkop failed"
assert_launchers forkop-direct "Forkop's launchers while Forkop's package is installed"
# Upstream Forkop's launchers carry only the former mirror's proxy path.
cat >"$WORK_DIR/expected/upstream" <<'EOF'
#!/bin/sh
export ZAPRET_MANAGER_MIRROR='https://mirror.infotechtg.ru'
exec sh <(wget -q -O - 'https://mirror.infotechtg.ru/zapret-manager/proxy/raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh') "$@"
EOF
install_launchers upstream
reconcile '' >/dev/null || fail "reconciling upstream launchers next to an installed Forkop failed"
assert_launchers upstream "upstream Forkop's launchers while Forkop's package is installed"

forkop_removed
out="$(reconcile '')" || fail "reconciling Forkop's direct launchers failed"
assert_launchers prokop-direct "Forkop's direct launchers"
printf '%s\n' "$out" | grep -Fq "Updated $BIN/zms for the current dependency mirror setting" ||
  fail "rewriting Forkop's launchers was not reported: $out"

install_launchers forkop-mirrored
reconcile 'https://own-mirror.test/' >/dev/null || fail "reconciling Forkop's mirrored launchers failed"
assert_launchers prokop-mirrored "Forkop's mirrored launchers with the mirror kept"

install_launchers forkop-mirrored
reconcile '' >/dev/null || fail "reconciling Forkop's mirrored launchers without a mirror failed"
assert_launchers prokop-direct "Forkop's mirrored launchers with the mirror off"

# The LuCI system information reports Forkop's launchers as installed once
# Forkop's package is gone.
python3 - "$DIAGNOSTICS_UC" "$WORK_DIR/diagnostics.uc" <<'PY'
import re
import sys

source = open(sys.argv[1], encoding='utf-8').read()
parts = []
for name in ('managed_zapret_manager_launcher', 'zapret_manager_launchers_installed'):
    match = re.search(r'^function ' + name + r'\([^\n]*\) \{\n.*?^\}', source, re.M | re.S)
    if match is None:
        raise SystemExit('missing production function: ' + name)
    parts.append(re.sub(r'"/usr/bin/(zmsA?)"', r'BIN + "/\1"', match.group()))
prefix = r'''
let fs = require("fs");
let legacy_forkop = require("core.legacy_forkop");
const BIN = getenv("WORK_DIR") + "/bin";
function as_string(value) { return value == null ? "" : "" + value; }
function file_executable(path) { return system([ "test", "-x", path ]) == 0; }
'''
suffix = r'''
print(zapret_manager_launchers_installed(), "\n");
'''
open(sys.argv[2], 'w', encoding='utf-8').write(prefix + '\n\n'.join(parts) + suffix)
PY
install_launchers forkop-direct
[ "$(ucode -L "$PROKOP_LIB" "$WORK_DIR/diagnostics.uc")" = "1" ] ||
  fail "Forkop's launchers are not reported as installed"
forkop_installed
[ "$(ucode -L "$PROKOP_LIB" "$WORK_DIR/diagnostics.uc")" = "0" ] ||
  fail "Forkop's launchers were reported as Prokop's while Forkop's package is installed"
forkop_removed

printf 'prokop from forkop data markers: PASS\n'
