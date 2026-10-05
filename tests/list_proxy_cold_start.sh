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

# 1b. The rule the lists download through has no nodes yet: its subscription
#     downloads through rule main and was deferred at this start. No lists
#     proxy can be served; the first stage serves the subscription download
#     proxy of main instead, on the port subscription/cache.uc uses.
printf '%s\n' '{ "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"], "yacd_secret_key": "test-clash-secret", "download_lists_via_proxy": "1", "download_lists_via_proxy_section": "vpn" }, "section": [ { ".name": "main", ".type": "section", "enabled": "1", "action": "connection", "outbound_jsons": ["{\"type\":\"direct\",\"tag\":\"test\"}"] }, { ".name": "vpn", ".type": "section", "enabled": "1", "action": "connection", "subscription_urls": ["https://sub.test/vpn"], "subscription_url_settings": "{\"https://sub.test/vpn\":{\"download_via_proxy_enabled\":\"1\",\"download_via_proxy_section\":\"main\"}}", "remote_domain_lists": ["https://lists.test/domains.txt"] } ] }' \
  >"$WORK/deferred.json"
if SB_SERVICE_MIXED_INBOUND_PORT=45399 generator generate-list-bootstrap-config-fixture "$WORK/deferred.json" \
  "$WORK/deferred.out.json" 192.0.2.1 0 1 vpn 1.12.9 "$WORK/scratch3" >/dev/null 2>&1; then
  fail "a lists proxy was generated through a rule without nodes"
fi
SB_SERVICE_MIXED_INBOUND_PORT=45399 generator generate-list-bootstrap-config-fixture "$WORK/deferred.json" \
  "$WORK/subscriptions.json" 192.0.2.1 0 1 vpn 1.12.9 "$WORK/scratch4" subscriptions >"$WORK/gen.log" 2>&1 ||
  fail "the subscription stage was not generated: $(cat "$WORK/gen.log")"
shape="$(ucode -e '
  let c = json(require("fs").readfile(ARGV[0]));
  print(join(" ", [
    length(c.inbounds), c.inbounds[0].tag, c.inbounds[0].listen_port,
    length(c.route.rules), c.route.rules[0].inbound, c.route.rules[0].outbound
  ]), "\n");' -- "$WORK/subscriptions.json")"
[ "$shape" = "1 service-subscription-main-in 45401 1 service-subscription-main-in main-out" ] ||
  fail "unexpected subscription stage configuration: $shape"
# The lists stage with another rule deferred still serves the lists proxy.
SB_SERVICE_MIXED_INBOUND_PORT=45399 generator generate-list-bootstrap-config-fixture "$WORK/proxied.json" \
  "$WORK/other.json" 192.0.2.1 0 1 other 1.12.9 "$WORK/scratch5" >"$WORK/gen.log" 2>&1 ||
  fail "the lists stage was not generated with another rule deferred: $(cat "$WORK/gen.log")"

# 2. The cold start runs it around the download, and stops it before routing.
line_of() { grep -n -F -- "$1" "$LIB/service/lifecycle.uc" | head -n 1 | cut -d: -f1; }
start_line="$(line_of '[ "list-bootstrap-start", subscription_deferred_sections ]')"
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

# sing-box marks its outbound connections (route.default_mark), which needs
# root as on the router.
if [ "$(id -u)" -ne 0 ]; then
  printf 'list_proxy_cold_start: OK (real sing-box not run: it needs root to mark its connections)\n'
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
    TMP_SUBSCRIPTION_FOLDER="$WORK/tmp/subscriptions" \
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

# 4. Another subscription rule was deferred at this start (its subscription
#    did not download): the start hands its deferred rules over, the
#    temporary sing-box starts all the same and they stay deferred. 2.17.0
#    prepared the caches again without downloads and stopped there.
reset_run() {
  local bootstrap=""
  read -r bootstrap _ 2>/dev/null <"$WORK/run/list-bootstrap/sing-box.pid" || true
  # shellcheck disable=SC2086
  [ -z "$bootstrap" ] || owned_kill KILL $bootstrap 2>/dev/null || true
  find "$WORK/run" -mindepth 1 -maxdepth 1 ! -name reload.lock -exec rm -rf {} +
  rm -rf "$WORK/tmp" "$WORK/cache" "$WORK/generation" "$WORK/subscription-cache" "$WORK/ruleset-cache"
  mkdir -p "$WORK/cache"
  : >"$WORK/curl.log"
}
reset_run
cat >>"$WORK/uci.state" <<UCI
prokop.other=section
prokop.other.enabled=1
prokop.other.action=connection
prokop.other.subscription_urls=https://127.0.0.1:1/missing.txt
UCI
runtime list-bootstrap-start other >"$WORK/start.log" 2>"$WORK/start.err" ||
  fail "the temporary sing-box did not start with another rule deferred: $(cat "$WORK/start.err" "$WORK/logger.log")"
[ "$(cat "$WORK/start.log")" = other ] || fail "the deferred rules were not handed back: $(cat "$WORK/start.log")"
updates prepare-list-cache >"$WORK/with.log" 2>&1 ||
  fail "the list download failed with another rule deferred: $(cat "$WORK/with.log" "$WORK/logger.log")"
runtime list-bootstrap-stop || fail "the temporary sing-box did not stop"

# 5. The rule the lists download through has no nodes yet: its subscription
#    did not download directly at this start and downloads through rule
#    main. The temporary sing-box first serves main's subscription download
#    proxy, the subscription downloads through it, and the lists then
#    download through the rule's new node: a shadowsocks server (a second
#    real sing-box) in front of the local list server.
SS_PORT="$(free_port)"
cat >"$WORK/ss.json" <<JSON
{ "log": { "level": "info", "timestamp": false },
  "inbounds": [ { "type": "shadowsocks", "listen": "127.0.0.1", "listen_port": $SS_PORT, "method": "aes-128-gcm", "password": "test-password" } ],
  "outbounds": [ { "type": "direct" } ] }
JSON
"$SING_BOX" run -c "$WORK/ss.json" >"$WORK/ss.log" 2>&1 &
pids+=("$!")
for _ in $(seq 100); do grep -q 'sing-box started' "$WORK/ss.log" && break; sleep 0.1; done
grep -q 'sing-box started' "$WORK/ss.log" || fail "the shadowsocks server did not start: $(cat "$WORK/ss.log")"
# Subscriptions download over HTTPS only: a local HTTPS server with a
# certificate the curl stand-in trusts.
mkdir -p "$WORK/subs"
printf 'ss://%s@127.0.0.1:%s#vpn-node\n' "$(printf 'aes-128-gcm:test-password' | base64 -w0)" "$SS_PORT" >"$WORK/subs/vpn.txt"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1 \
  -keyout "$WORK/tls.key" -out "$WORK/tls.crt" >/dev/null 2>&1 || fail "could not make a test certificate"
HTTPS_PORT="$(free_port)"
python3 - "$HTTPS_PORT" "$WORK/subs" "$WORK/tls.crt" "$WORK/tls.key" >"$WORK/https.log" 2>&1 <<'PY' &
import functools, http.server, ssl, sys
port, root, crt, key = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
server = http.server.HTTPServer(("127.0.0.1", port), handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(crt, key)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PY
pids+=("$!")
for _ in $(seq 50); do
  curl -s --noproxy '*' --cacert "$WORK/tls.crt" -o /dev/null "https://127.0.0.1:$HTTPS_PORT/vpn.txt" && break
  sleep 0.1
done

# Every subscription request of rule vpn must go through a proxy.
REAL_CURL="$(command -v curl)"
cat >"$WORK/bin/curl" <<SH
#!/bin/sh
url=""; proxy=direct; prev=""
for arg in "\$@"; do
  case "\$prev" in
    -x|--proxy) proxy="\$arg" ;;
    -K) url="\$(sed -n 's/^url = "\\(.*\\)"\$/\\1/p' "\$arg")" ;;
  esac
  case "\$arg" in http://* | https://*) url="\$arg" ;; esac
  prev="\$arg"
done
printf '%s proxy=%s\n' "\$url" "\$proxy" >>"$WORK/curl.log"
exec "$REAL_CURL" --cacert "$WORK/tls.crt" "\$@"
SH
chmod +x "$WORK/bin/curl"

reset_run
cat >"$WORK/uci.state" <<UCI
prokop.settings=settings
prokop.settings.dns_server=77.88.8.8
prokop.settings.bootstrap_dns_server=77.88.8.8
prokop.settings.download_lists_via_proxy=1
prokop.settings.download_lists_via_proxy_section=vpn
prokop.main=section
prokop.main.enabled=1
prokop.main.action=connection
prokop.main.outbound_jsons={"type":"direct","tag":"test"}
prokop.vpn=section
prokop.vpn.enabled=1
prokop.vpn.action=connection
prokop.vpn.subscription_urls=https://127.0.0.1:$HTTPS_PORT/vpn.txt
prokop.vpn.subscription_url_settings={"https://127.0.0.1:$HTTPS_PORT/vpn.txt":{"download_via_proxy_enabled":"1","download_via_proxy_section":"main"}}
prokop.vpn.remote_domain_lists=http://127.0.0.1:$HTTP_PORT/domains.txt
UCI
runtime list-bootstrap-start vpn >"$WORK/start.log" 2>"$WORK/start.err" ||
  fail "the temporary sing-box did not start for a rule without nodes: $(cat "$WORK/start.err" "$WORK/logger.log")"
[ -z "$(cat "$WORK/start.log")" ] || fail "the rule stays deferred after its subscription downloaded: $(cat "$WORK/start.log")"
grep -q "/vpn.txt proxy=.*127.0.0.1:$((PROXY_PORT + 2))" "$WORK/curl.log" ||
  fail "the subscription was not downloaded through rule main's proxy: $(cat "$WORK/curl.log")"
! grep -q '/vpn.txt proxy=direct' "$WORK/curl.log" || fail "the subscription was downloaded directly: $(cat "$WORK/curl.log")"
updates prepare-list-cache >"$WORK/with.log" 2>&1 ||
  fail "the list download through the rule's new node failed: $(cat "$WORK/with.log" "$WORK/logger.log")"
grep -q "outbound/shadowsocks\[.*\]: outbound connection to 127.0.0.1:$HTTP_PORT" "$WORK/run/list-bootstrap/sing-box.log" ||
  fail "the lists were not downloaded through the rule's node: $(cat "$WORK/run/list-bootstrap/sing-box.log")"
runtime list-bootstrap-stop || fail "the temporary sing-box did not stop"
updates restore-list-cache || fail "the downloaded list generation is not usable"

# 6. Its subscription does not download through main either: the start
#    stops (fail closed), nothing is downloaded directly and no temporary
#    sing-box is left.
reset_run
mv "$WORK/subs/vpn.txt" "$WORK/subs/vpn.gone"
if runtime list-bootstrap-start vpn >"$WORK/start.log" 2>"$WORK/start.err"; then
  fail "the temporary sing-box started for a rule whose subscription did not download"
fi
grep -q '/vpn.txt proxy=.*127.0.0.1:' "$WORK/curl.log" || fail "the subscription download was not tried through main: $(cat "$WORK/curl.log")"
! grep -q 'proxy=direct' "$WORK/curl.log" || fail "something was downloaded directly: $(cat "$WORK/curl.log")"
grep -q 'has no nodes' "$WORK/logger.log" || fail "the log does not say why the start stops: $(cat "$WORK/logger.log")"
[ ! -e "$WORK/run/list-bootstrap" ] || fail "the failed bootstrap left the temporary sing-box files"

printf 'list_proxy_cold_start: OK (real sing-box)\n'
