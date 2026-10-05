#!/usr/bin/env bash
set -euo pipefail
# C4: the server chosen in a selector outlives a reboot. A choice the user
# made through Prokop, and the selection at a stop (also one made on the
# dashboard), go to a small map on flash, written only on a change; a start
# that found no sing-box cache file puts it back, skipping groups and tags
# that are gone. Prokop's own switches (priority failover, a restore) are
# not recorded.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
RUNTIME_UC="$PROKOP_LIB/diagnostics/runtime.uc"
LIFECYCLE_UC="$PROKOP_LIB/service/lifecycle.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/answers" "$WORK/run"
# The controller double: GET /proxies answers proxies.json, a PUT is logged
# and answered 204 unless put.fail exists.
cat >"$WORK/bin/curl" <<'SH'
#!/bin/sh
method=GET
url=""
for arg in "$@"; do
  case "$arg" in
    PUT) method=PUT ;;
    *127.0.0.1:9090/*) url="${arg#*127.0.0.1:9090/}" ;;
  esac
done
if [ "$method" = PUT ]; then
  printf 'PUT %s\n' "$url" >>"$FAKE_ANSWERS/puts"
  if [ -e "$FAKE_ANSWERS/put.fail" ]; then printf '{"message":"x"}\n500'; else printf '\n204'; fi
  exit 0
fi
[ "$url" = proxies ] && cat "$FAKE_ANSWERS/proxies.json"
exit 0
SH
chmod +x "$WORK/bin/curl"
cat >"$WORK/uci-state" <<'EOF'
prokop.settings=settings
EOF

CHOICES="$WORK/etc/selector-choices.json"
export FAKE_ANSWERS="$WORK/answers" PROKOP_LIB PATH="$WORK/bin:$PATH" \
  PROKOP_UCI_STATE_FILE="$WORK/uci-state" PROKOP_RUNTIME_STATE_DIR="$WORK/run" \
  PROKOP_SELECTOR_CHOICES_FILE="$CHOICES"

clash() { ucode -L "$PROKOP_LIB" "$RUNTIME_UC" clash-api "$@" >/dev/null 2>&1; }
lifecycle() { ucode -L "$PROKOP_LIB" "$LIFECYCLE_UC" "$@" 2>/dev/null; }
saved() { tr -d '[:space:]' <"$CHOICES"; }
inode() { stat -c %i "$CHOICES"; }

cat >"$WORK/answers/proxies.json" <<'JSON'
{"proxies":{
  "main":{"type":"Selector","now":"proxy-a","all":["proxy-a","proxy-b"]},
  "extra":{"type":"Selector","now":"x-1","all":["x-1","x-2"]},
  "sec-priority-pg-out-probe":{"type":"Selector","now":"x-2","all":["x-1","x-2"]},
  "auto":{"type":"URLTest","now":"proxy-a","all":["proxy-a","proxy-b"]}
}}
JSON

# 1. The user's choice is saved, private, and written only when it changed.
clash set_group_proxy main proxy-b || fail "set_group_proxy failed"
[ "$(saved)" = '{"main":"proxy-b"}' ] || fail "the choice was not saved: $(cat "$CHOICES" 2>&1)"
[ "$(stat -c %a "$CHOICES")" = 600 ] || fail "the choices file is not private"
before="$(inode)"
clash set_group_proxy main proxy-b
[ "$(inode)" = "$before" ] || fail "an unchanged choice rewrote the file"

# 2. Prokop's own switches and a refused switch are not recorded.
clash set_group_proxy main proxy-a auto
[ "$(saved)" = '{"main":"proxy-b"}' ] || fail "an automatic switch was recorded: $(saved)"
: >"$WORK/answers/put.fail"
clash set_group_proxy main proxy-a || :
rm "$WORK/answers/put.fail"
[ "$(saved)" = '{"main":"proxy-b"}' ] || fail "a refused switch was recorded: $(saved)"
grep -q 'set_group_proxy", group.tag, tag_name, "auto"' "$PROKOP_LIB/singbox/priority.uc" ||
  fail "priority failover switches are recorded as the user's choice"

# 3. The selection at a stop is kept, the URLTest group and the probe
#    selector of a payload check (C15) are not.
lifecycle selector-capture-fixture >/dev/null
[ "$(saved)" = '{"main":"proxy-a","extra":"x-1"}' ] || fail "the stop did not keep the selection: $(saved)"

# 3b. A Priority group's selector is the priority worker's last switch, not
#     a choice: it is not kept on flash (LC-9). The section caches of the
#     running generation name those groups.
mkdir -p "$WORK/run/section-cache"
printf '%s\n' '{"priorityGroups":{"sec-priority-pg-out":{"tag":"sec-priority-pg-out","probe_tag":""}}}' \
  >"$WORK/run/section-cache/sec.json"
cp "$WORK/answers/proxies.json" "$WORK/answers/proxies.saved"
sed 's/"auto":/"sec-priority-pg-out":{"type":"Selector","now":"x-2","all":["x-1","x-2"]},\n  "auto":/' \
  "$WORK/answers/proxies.saved" >"$WORK/answers/proxies.json"
rm -f "$CHOICES"
lifecycle selector-capture-fixture >/dev/null
[ "$(saved)" = '{"main":"proxy-a","extra":"x-1"}' ] || fail "a Priority group's selector was kept: $(saved)"
# 3c. A reboot runs no stop: the shutdown hook records the selection
#     (/etc/init.d/prokop shutdown, K01).
rm -f "$CHOICES"
lifecycle capture-selector-state || fail "the shutdown hook failed"
[ "$(saved)" = '{"main":"proxy-a","extra":"x-1"}' ] || fail "the shutdown hook did not keep the selection: $(cat "$CHOICES" 2>&1)"
grep -q '^STOP=01$' "$ROOT_DIR/prokop/files/etc/init.d/prokop" &&
  awk '/^shutdown\(\)/{f=1} f&&/capture-selector-state/{ok=1} f&&/^}/{exit} END{exit !ok}' "$ROOT_DIR/prokop/files/etc/init.d/prokop" ||
  fail "a reboot does not run the shutdown hook"
cp "$WORK/answers/proxies.saved" "$WORK/answers/proxies.json"
rm -rf "$WORK/run/section-cache"

# 4. After a reboot every selector is on its default: the saved choices go
# back, a gone tag and a gone group are skipped, and the restore itself is
# not recorded as the user's choice.
printf '{"main":"proxy-b","extra":"x-9","gone":"proxy-a"}\n' >"$CHOICES"
: >"$WORK/answers/puts"
lifecycle selector-saved-restore-fixture >/dev/null
[ "$(cat "$WORK/answers/puts")" = 'PUT proxies/main' ] ||
  fail "the restore did not set exactly the still valid choice: $(cat "$WORK/answers/puts")"
[ "$(saved)" = '{"main":"proxy-b","extra":"x-9","gone":"proxy-a"}' ] || fail "the restore rewrote the choices: $(saved)"

# 5. A torn or foreign file reads as no choices and is replaced on the next one.
printf '{"main":' >"$CHOICES"
: >"$WORK/answers/puts"
lifecycle selector-saved-restore-fixture >/dev/null
[ ! -s "$WORK/answers/puts" ] || fail "a torn file restored something"
clash set_group_proxy extra x-2
[ "$(saved)" = '{"extra":"x-2"}' ] || fail "a torn file was not replaced: $(saved)"

# 6. The map is capped; the oldest choices go first.
ucode -L "$PROKOP_LIB" -e '
let c = require("core.selector_choices");
for (let i = 0; i < 300; i++) c.record_choices({ ["g" + i]: "t" });
c.record_choices({ g100: "again" });
let saved = c.read_choices(), names = keys(saved);
if (length(names) != c.MAX_CHOICES || saved.g0 != null || saved.g299 != "t" ||
    names[length(names) - 1] != "g100")
  die(sprintf("cap: %d names, first %s, last %s\n", length(names), names[0], names[length(names) - 1]));
' || fail "the choices map is not capped as expected"

# 7. The start restores only when sing-box lost its cache file, and stop
# keeps the selection.
if ! grep -q 'let selector_cache_lost = fs.stat(selector_cache_path()) == null;' "$LIFECYCLE_UC" ||
  ! grep -q 'restore_selector_state(selector_choices.read_choices());' "$LIFECYCLE_UC"; then
  fail "the start does not restore the saved choices"
fi
awk '/^function stop\(\)/{f=1} f&&/capture_selector_state\(\);/{ok=1} f&&/^}/{exit} END{exit !ok}' "$LIFECYCLE_UC" ||
  fail "stop does not keep the selection"

echo "selector_choices: OK"
