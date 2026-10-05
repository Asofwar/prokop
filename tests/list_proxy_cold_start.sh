#!/usr/bin/env bash
set -euo pipefail

# A9: the first start without a list cache, with lists downloaded through a
# rule's proxy ("download_lists_via_proxy").
#
# A start prepares the list generation before routing starts, and the lists
# service proxy it downloads through belongs to the sing-box that starts
# afterwards. Every download failed and the start aborted, on every start,
# until the option was turned off by hand. Now the start runs a temporary
# sing-box that serves only that proxy, downloads, stops it and goes on.
#
# 1. The temporary configuration: the rule outbounds, DNS and the lists
#    service proxy inbound routed to the configured rule. It is generated
#    where the full configuration cannot be (the lists do not exist yet).
# 2. lifecycle starts it before the download and stops it before routing.
# 3. With $PROKOP_TEST_SING_BOX (or sing-box on PATH): the real sing-box
#    starts from it, the real list update downloads through it from a local
#    server, and it is stopped. Without it the same download fails.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
# shellcheck source=tests/helpers/owned_processes.sh
. "$ROOT_DIR/tests/helpers/owned_processes.sh"

pids=()
cleanup() {
  local bootstrap=""
  read -r bootstrap _ 2>/dev/null <"$WORK/run/list-bootstrap/sing-box.pid" || true
  # shellcheck disable=SC2086
  owned_kill KILL "${pids[@]}" $bootstrap 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# 1. The temporary configuration.
fixture() {
  printf '{ "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"], "yacd_secret_key": "test-clash-secret"%s }, "section": [ { ".name": "main", ".type": "section", "enabled": "1", "action": "connection", "outbound_jsons": ["{\\"type\\":\\"direct\\",\\"tag\\":\\"test\\"}"], "remote_domain_lists": ["https://lists.test/domains.txt"] } ] }\n' \
    "$2" >"$WORK/$1.json"
}
fixture proxied ', "download_lists_via_proxy": "1", "download_lists_via_proxy_section": "main"'
fixture direct ''
generator() { ucode -L "$LIB" "$LIB/singbox/generator.uc" "$@"; }

if generator generate-config-fixture "$WORK/proxied.json" "$WORK/full.json" 192.0.2.1 0 1 '' 1.12.9 >/dev/null 2>&1; then
  fail "the full configuration was generated without the lists; the case does not show the cold start"
fi
SB_SERVICE_MIXED_INBOUND_PORT=45399 generator generate-list-bootstrap-config-fixture "$WORK/proxied.json" \
  "$WORK/bootstrap.json" 192.0.2.1 0 1 '' 1.12.9 "$WORK/scratch" >"$WORK/gen.log" 2>&1 ||
  fail "the temporary list configuration was not generated: $(cat "$WORK/gen.log")"
shape="$(ucode -e '
  let c = json(require("fs").readfile(ARGV[0]));
  let tags = map(c.outbounds, (o) => o.tag);
  print(join(" ", [
    length(c.inbounds), c.inbounds[0].type, c.inbounds[0].tag, c.inbounds[0].listen, c.inbounds[0].listen_port,
    length(c.route.rules), c.route.rules[0].inbound, c.route.rules[0].outbound,
    length(c.route.rule_set), length(c.dns.rules), length(keys(c.experimental)), c.log.level,
    index(tags, "main-out") >= 0, index(tags, "test") >= 0
  ]), "\n");' -- "$WORK/bootstrap.json")"
[ "$shape" = "1 mixed service-mixed-in 127.0.0.1 45399 1 service-mixed-in main-out 0 0 0 info true true" ] ||
  fail "unexpected temporary list configuration: $shape"
# The rule's dashboard state goes to the scratch directory, not to the
# runtime one the real start fills.
[ -s "$WORK/scratch/section-cache/main.json" ] || fail "the generation state did not go to the scratch directory: $(ls -R "$WORK/scratch" 2>&1)"
if generator generate-list-bootstrap-config-fixture "$WORK/direct.json" "$WORK/direct.out.json" 192.0.2.1 0 1 '' 1.12.9 "$WORK/scratch2" >/dev/null 2>&1; then
  fail "a temporary list configuration was generated although lists are not downloaded through a proxy"
fi

# 2. The cold start runs it around the download, and stops it before routing.
line_of() { grep -n -F -- "$1" "$LIB/service/lifecycle.uc" | head -n 1 | cut -d: -f1; }
start_line="$(line_of '[ "list-bootstrap-start" ]')"
prepare_line="$(line_of '[ "prepare-list-cache" ]')"
stop_line="$(sed -n "${prepare_line:-1},\$p" "$LIB/service/lifecycle.uc" | grep -n -F '[ "list-bootstrap-stop" ]' | head -n 1 | cut -d: -f1)"
nft_line="$(line_of 'if (!nft_candidate_begin())')"
{ [ -n "$start_line" ] && [ -n "$prepare_line" ] && [ -n "$stop_line" ] && [ -n "$nft_line" ]; } ||
  fail "the cold start does not run the temporary sing-box around the list download"
stop_line=$((prepare_line + stop_line - 1))
{ [ "$start_line" -lt "$prepare_line" ] && [ "$stop_line" -lt "$nft_line" ]; } ||
  fail "the temporary sing-box does not run around the list download (lines $start_line, $prepare_line, $stop_line, $nft_line)"

SING_BOX="${PROKOP_TEST_SING_BOX:-$(command -v sing-box 2>/dev/null || true)}"
if [ -z "$SING_BOX" ] || [ ! -x "$SING_BOX" ]; then
  printf 'list_proxy_cold_start: OK (real sing-box not run: set PROKOP_TEST_SING_BOX)\n'
  exit 0
fi

# 3. The real sing-box and the real list update.
mkdir -p "$WORK/bin" "$WORK/run" "$WORK/cache" "$WORK/rulesets" "$WORK/www"
ln -s "$SING_BOX" "$WORK/bin/sing-box"
# shellcheck disable=SC2016
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$LOGGER_LOG"\n' >"$WORK/bin/logger"
printf '#!/bin/sh\nexit 1\n' >"$WORK/bin/nft"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/init-prokop"
chmod +x "$WORK/bin/logger" "$WORK/bin/nft" "$WORK/bin/init-prokop"
printf 'cold.example\n' >"$WORK/www/domains.txt"

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }
HTTP_PORT="$(free_port)"
PROXY_PORT="$(free_port)"
python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$WORK/www" >"$WORK/http.log" 2>&1 &
pids+=("$!")
for _ in $(seq 50); do
  curl -s --noproxy '*' -o /dev/null "http://127.0.0.1:$HTTP_PORT/domains.txt" && break
  sleep 0.1
done

cat >"$WORK/uci.state" <<UCI
prokop.settings=settings
prokop.settings.dns_server=77.88.8.8
prokop.settings.bootstrap_dns_server=77.88.8.8
prokop.settings.download_lists_via_proxy=1
prokop.settings.download_lists_via_proxy_section=main
prokop.main=section
prokop.main.enabled=1
prokop.main.action=connection
prokop.main.outbound_jsons={"type":"direct","tag":"test"}
prokop.main.remote_domain_lists=http://127.0.0.1:$HTTP_PORT/domains.txt
UCI

# The download goes to the proxy only: no proxy settings of the host.
prokop_env() {
  env -u no_proxy -u NO_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
    PATH="$WORK/bin:$PATH" LOGGER_LOG="$WORK/logger.log" PROKOP_LIB="$LIB" \
    PROKOP_UCI_STATE_FILE="$WORK/uci.state" TMP_SING_BOX_FOLDER="$WORK/tmp" TMP_RULESET_FOLDER="$WORK/rulesets" \
    PROKOP_RUNTIME_STATE_DIR="$WORK/run" PROKOP_RELOAD_LOCK_DIR="$WORK/run/reload.lock" \
    PROKOP_LIST_UPDATE_PID_FILE="$WORK/run/list.pid" PROKOP_PERSISTENT_LIST_CACHE_DIR="$WORK/cache" \
    PROKOP_RULESET_CACHE_DIR="$WORK/ruleset-cache" PROKOP_RUNTIME_LIST_GENERATION_DIR="$WORK/generation" \
    PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK/subscription-cache" \
    PROKOP_SERVICE_INIT="$WORK/bin/init-prokop" SB_SERVICE_MIXED_INBOUND_PORT="$PROXY_PORT" \
    ucode -L "$LIB" "$@"
}
updates() { prokop_env "$LIB/components/updates.uc" "$@"; }
runtime() { prokop_env "$LIB/singbox/runtime.uc" "$@"; }

# A start owns reload.lock while it prepares the lists.
ucode -L "$LIB" "$LIB/service/state.uc" acquire-runtime-dir-lock "$WORK/run/reload.lock" "$$" ||
  fail "could not take reload.lock as the start does"

if updates prepare-list-cache >"$WORK/without.log" 2>&1; then
  fail "the list download through the rule's proxy succeeded with no sing-box running"
fi
updates restore-list-cache && fail "a list generation exists after the failed download"

runtime list-bootstrap-start >"$WORK/start.log" 2>&1 ||
  fail "the temporary sing-box did not start: $(cat "$WORK/start.log" "$WORK/logger.log")"
read -r bootstrap_pid _ <"$WORK/run/list-bootstrap/sing-box.pid" || fail "the temporary sing-box has no pidfile"
updates prepare-list-cache >"$WORK/with.log" 2>&1 ||
  fail "the list download through the temporary sing-box failed: $(cat "$WORK/with.log" "$WORK/logger.log")"
grep -q 'outbound/direct\[test\]: outbound connection to 127.0.0.1:'"$HTTP_PORT" "$WORK/run/list-bootstrap/sing-box.log" ||
  fail "the lists were not downloaded through the rule's outbound: $(cat "$WORK/run/list-bootstrap/sing-box.log")"
runtime list-bootstrap-stop || fail "the temporary sing-box did not stop"
# A zombie the container's init did not reap yet does not run.
alive() { [ -e "/proc/$1" ] && [ "$(sed -n 's/^State:[[:space:]]*\([A-Z]\).*/\1/p' "/proc/$1/status" 2>/dev/null)" != Z ]; }
alive "$bootstrap_pid" && fail "the temporary sing-box still runs after the stop"
[ ! -e "$WORK/run/list-bootstrap" ] || fail "the temporary sing-box left its files"
updates restore-list-cache || fail "the downloaded list generation is not usable"

# A pidfile left by a start that died names a process that is not the
# temporary sing-box any more: the stop leaves it alone.
mkdir -p "$WORK/run/list-bootstrap"
sleep 300 &
other=$!
pids+=("$other")
ucode -L "$LIB" "$LIB/core/pidfile_cli.uc" record "$other" "$WORK/run/list-bootstrap/sing-box.pid" ||
  fail "could not record the unrelated process"
runtime list-bootstrap-stop || fail "the stop failed on a pidfile of an unrelated process"
alive "$other" || fail "the stop killed a process that was not the temporary sing-box"

printf 'list_proxy_cold_start: OK (real sing-box)\n'
