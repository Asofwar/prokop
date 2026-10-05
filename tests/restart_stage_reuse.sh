#!/usr/bin/env bash
set -euo pipefail

# B6: a restart of a running Prokop generates, materializes and checks the
# sing-box configuration into a stage while the old runtime still serves
# (prepare-config-stage ... reusable). Its start used to throw that stage
# away and generate, materialize and check the same configuration again.
# Now the start (init-config ... <stage>) publishes the checked stage when a
# fingerprint of everything a generation reads is what it was at the
# precheck, and generates again as before when anything differs, when the
# stage or its record is damaged, or when the precheck's generation asked
# the network or changed what it read.
#
# singbox/runtime.uc, generator.uc and ruleset_cache.uc run for real from a
# copy of the library whose generator.uc counts its runs; sing-box (which
# counts its checks), logger and nft are stand-ins.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_LIB="$ROOT_DIR/prokop/files/usr/lib"
W="$(mktemp -d)"
trap 'rm -rf "${W:?}"' EXIT
trap 'exit 1' HUP INT TERM
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$W/logger.log" ] || sed 's/^/  log: /' "$W/logger.log" >&2
  exit 1
}

LIB="$W/lib"
mkdir -p "$W/bin" "$W/tmp"
cp -R "$REAL_LIB" "$LIB"
mv "$LIB/singbox/generator.uc" "$LIB/singbox/generator_real.uc"
cat >"$LIB/singbox/generator.uc" <<'UC'
function q(value) { return "'" + replace("" + value, /'/g, "'\\''") + "'"; }
let lib = getenv("PROKOP_LIB");
system("printf 'generate\\n' >>" + q(getenv("TEST_COUNTS")));
let command = "ucode -L " + q(lib) + " " + q(lib + "/singbox/generator_real.uc");
for (let arg in ARGV)
    command += " " + q(arg);
let status = system(command);
// A generation that asked the network does not mark itself offline.
if ((getenv("TEST_GENERATION_ASKED_NETWORK") || "") == "1")
    system("rm -f " + q(ARGV[1] + ".offline"));
exit(status);
UC
cat >"$W/bin/sing-box" <<'SH'
#!/bin/sh
[ "$1" = version ] && { printf 'sing-box version %s\n' "$(cat "$TEST_SING_BOX_VERSION")"; exit 0; }
printf 'check\n' >>"$TEST_COUNTS"
exit 0
SH
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/logger.log"\n' "$W" >"$W/bin/logger"
printf '#!/bin/sh\nexit 1\n' >"$W/bin/nft"
chmod +x "$W/bin/"*

export TEST_COUNTS="$W/counts" TEST_SING_BOX_VERSION="$W/sing-box-version"
E() {
  env PATH="$W/bin:$PATH" PROKOP_LIB="$LIB" PROKOP_UCI_STATE_FILE="$W/uci.state" PROKOP_RUNTIME_STATE_DIR="$W/run" \
    TMP_RULESET_FOLDER="$W/rulesets" TMP_SING_BOX_FOLDER="$W/tmp/sing-box" TMP_SUBSCRIPTION_FOLDER="$W/tmp/subscriptions" \
    PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$W/subcache" PROKOP_RULESET_CACHE_DIR="$W/cache" \
    PROKOP_PERSISTENT_LIST_CACHE_DIR="$W/listcache" PROKOP_DNS_FAILOVER_STATE_FILE="$W/run/dns-failover.json" \
    PROKOP_RULESET_RUNTIME_CACHE_DIR="$W/rtcache" PROKOP_RULESET_RUNTIME_MANIFEST="$W/run/rt.json" \
    PROKOP_IPV6_SYSCTL_DIR="$W/ipv6" SB_VARIANT_STATE_FILE="$W/sb-variant" SB_VERSION_STATE_FILE="$W/sb-version" \
    PROKOP_PERSISTENT_LIST_CACHE_MIN_FREE_BYTES=0 TMPDIR="$W/tmp" "$@"
}
runtime() { E ucode -L "$LIB" "$LIB/singbox/runtime.uc" "$@"; }

STAGE="$W/tmp/stage.json"
CONFIG="$W/etc/config.json"

reset_case() {
  local dir
  for dir in run rulesets tmp subcache cache listcache rtcache ipv6 etc; do
    rm -rf "${W:?}/$dir"
  done
  rm -f "${W:?}/counts" "${W:?}/logger.log" "${W:?}/local.lst" "${W:?}/sb-variant"
  printf '1.12.9\n' >"$TEST_SING_BOX_VERSION"
  mkdir -p "$W/run/section-cache" "$W/rulesets" "$W/tmp" "$W/cache" "$W/rtcache" "$W/ipv6/conf/all" "$W/ipv6/conf/lo" "$W/etc"
  printf '0\n' >"$W/ipv6/conf/all/disable_ipv6"
  printf '0\n' >"$W/ipv6/conf/lo/disable_ipv6"
  printf 'pinned-seed-0001\n' >"$W/run/urltest-seed"
  printf '{"running":"old config"}\n' >"$CONFIG"
  printf '{"running":"old generation"}\n' >"$W/run/section-cache/main.json"
  : >"$W/counts"
  cat >"$W/uci.state" <<UCI
prokop.settings=settings
prokop.settings.config_path=$CONFIG
prokop.settings.dns_server=77.88.8.8
prokop.settings.bootstrap_dns_server=77.88.8.8
prokop.main=section
prokop.main.enabled=1
prokop.main.action=connection
prokop.main.outbound_jsons={"type":"direct","tag":"NEW-NODE"}
UCI
}

# The running Prokop's own start: what a generation leaves (the rule-set
# cache manifest, the published section caches) is there before a restart.
running_prokop() {
  runtime init-config 0 1 1 "" >/dev/null 2>&1 || fail "the running Prokop did not start"
  printf '{"running":"old config"}\n' >"$CONFIG"
  printf '{"running":"old generation"}\n' >"$W/run/section-cache/main.json"
  : >"$W/counts"
}

generations() { grep -c '^generate$' "$W/counts" || true; }
checks() { grep -c '^check$' "$W/counts" || true; }
precheck() {
  runtime prepare-config-stage 0 0 1 "" "$STAGE" reusable >/dev/null 2>&1 || fail "$1: the precheck refused the candidate"
}
start() { runtime init-config 0 1 1 "${2:-}" "$STAGE" >/dev/null 2>&1 || fail "$1: the start failed"; }
stage_gone() {
  { [ ! -e "$STAGE" ] && [ ! -e "$STAGE.fingerprint" ] && [ ! -e "$STAGE.section-cache" ]; } ||
    fail "$1: the checked stage was left behind: $(find "$W/tmp" -maxdepth 1 -name 'stage.json*' | tr '\n' ' ')"
  [ -z "$(find "$W/tmp" -maxdepth 1 -name '*.offline')" ] || fail "$1: a generation marker was left behind"
}
regenerated() {
  [ "$(generations)" = 2 ] || fail "$1: the start did not generate again ($(generations) generations)"
  [ "$(checks)" = 2 ] || fail "$1: the start did not check again ($(checks) checks)"
  stage_gone "$1"
  grep -q '"outbounds"' "$CONFIG" || fail "$1: the start published no configuration"
}

# ---- (a) nothing changed: the start publishes the checked stage ------------

reset_case
running_prokop
precheck "unchanged"
{ [ "$(generations)" = 1 ] && [ "$(checks)" = 1 ]; } || fail "the precheck did not generate and check once"
[ -s "$STAGE.fingerprint" ] || fail "the reusable stage has no fingerprint"
[ "$(stat -c %a "$STAGE.fingerprint")" = 600 ] || fail "the fingerprint record is not private"
cp "$STAGE" "$W/staged-config.json"
grep -q 'old generation' "$W/run/section-cache/main.json" || fail "the precheck published its section cache"
start "unchanged"
[ "$(generations)" = 1 ] || fail "the start generated again although nothing changed ($(generations) generations)"
[ "$(checks)" = 1 ] || fail "the start checked again although nothing changed ($(checks) checks)"
cmp -s "$W/staged-config.json" "$CONFIG" || fail "the start did not publish the checked stage"
grep -q 'NEW-NODE' "$W/run/section-cache/main.json" || fail "the start did not publish the stage's section cache (LC-8)"
stage_gone "unchanged"
grep -q 'checked before the restart' "$W/logger.log" || fail "the reuse is not logged"
# What it published is what a generation from the same inputs publishes.
cp "$CONFIG" "$W/reused.json"
runtime init-config 0 1 1 "" >/dev/null 2>&1 || fail "the plain start failed"
cmp -s "$W/reused.json" "$CONFIG" || fail "the reused configuration differs from a fresh generation"
printf 'OK: unchanged inputs: 1 generation and 1 check instead of 2 and 2\n'

# The stop removes the rule-set files and the start writes them again
# (apply-list-cache): the same content is the same input.
reset_case
printf '{"version":2,"rules":[]}\n' >"$W/rulesets/list.json"
running_prokop
precheck "rule-set files written again"
rm -f "$W/rulesets/list.json"
printf '{"version":2,"rules":[]}\n' >"$W/rulesets/list.json"
start "rule-set files written again"
[ "$(generations)" = 1 ] || fail "rule-set files written again with the same content made the start generate again"
stage_gone "rule-set files written again"
printf 'OK: rule-set files written again with the same content: still 1 generation\n'

# A stage of a reload (no "reusable") records no fingerprint.
reset_case
running_prokop
runtime prepare-config-stage 0 0 1 "" "$STAGE" >/dev/null 2>&1 || fail "the reload stage was refused"
[ ! -e "$STAGE.fingerprint" ] || fail "a reload stage computed a fingerprint"
start "reload stage"
regenerated "a stage without fingerprint"
printf 'OK: a stage without fingerprint -> generated again\n'

# ---- (b) each kind of input that changed between precheck and start --------

changed_case() {
  local what="$1" mutation="$2" deferred="${3:-}"
  reset_case
  running_prokop
  precheck "$what"
  [ -s "$STAGE.fingerprint" ] || fail "$what: the precheck recorded no fingerprint"
  eval "$mutation"
  start "$what" "$deferred"
  regenerated "$what"
  grep -q 'no longer matches' "$W/logger.log" || fail "$what: the regeneration is not logged"
  printf 'OK: %s -> generated again\n' "$what"
}

changed_case "UCI option" "sed -i 's/NEW-NODE/CHANGED-NODE/' '$W/uci.state'"
grep -q 'CHANGED-NODE' "$CONFIG" || fail "the regeneration did not use the changed UCI configuration"
changed_case "UCI option added" "printf 'prokop.settings.log_level=debug\n' >>'$W/uci.state'"
changed_case "section cache" "printf '{}\n' >'$W/run/section-cache/other.json'"
changed_case "subscription cache" \
  "mkdir -p '$W/tmp/subscriptions' && printf '{\"outbounds\":[]}\n' >'$W/tmp/subscriptions/sub.json'"
changed_case "persistent subscription cache" \
  "mkdir -p '$W/subcache' && printf 'x\n' >'$W/subcache/sub.metadata.json'"
changed_case "rule-set file" "printf '{\"version\":2,\"rules\":[]}\n' >'$W/rulesets/list.json'"
changed_case "rule-set cache" "printf '{}\n' >'$W/cache/manifest.json'"
changed_case "persistent list cache" "mkdir -p '$W/listcache' && printf 'x\n' >'$W/listcache/active'"
changed_case "DNS-failover state" "printf '{\"main\":1}\n' >'$W/run/dns-failover.json'"
changed_case "urltest seed" "printf 'another-seed-0002\n' >'$W/run/urltest-seed'"
changed_case "IPv6 availability" "printf '1\n' >'$W/ipv6/conf/all/disable_ipv6'"
changed_case "running configuration" "printf '{\"running\":\"patched by DNS failover\"}\n' >'$CONFIG'"
changed_case "deferred subscription rules" ":" "main"
changed_case "environment" "export SB_DNS_INBOUND_ADDRESS=127.0.0.53"
unset SB_DNS_INBOUND_ADDRESS
changed_case "sing-box version" "printf '1.12.10\n' >'$W/sing-box-version'"
changed_case "sing-box binary" \
  "cp '$W/bin/sing-box' '$W/sing-box.new' && printf '# rebuilt\n' >>'$W/sing-box.new' && mv '$W/sing-box.new' '$W/bin/sing-box'"
changed_case "sing-box variant" "printf 'extended\n' >'$W/sb-variant'"
changed_case "generator code" "printf '// changed\n' >>'$LIB/singbox/route.uc'"
changed_case "file a UCI option names" \
  "printf 'prokop.settings.note=%s\n' '$W/local.lst' >>'$W/uci.state'"
# The option was there at the precheck; the file it names appears.
reset_case
printf 'prokop.settings.note=%s\n' "$W/local.lst" >>"$W/uci.state"
running_prokop
precheck "local file"
[ -s "$STAGE.fingerprint" ] || fail "local file: the precheck recorded no fingerprint"
printf 'example.org\n' >"$W/local.lst"
start "local file"
regenerated "a file a UCI option names changed"
printf 'OK: a file a UCI option names changed -> generated again\n'

# A file the configuration itself names (a certificate).
reset_case
printf 'cert one\n' >"$W/cert.pem"
sed -i "s|\"tag\":\"NEW-NODE\"}|\"tag\":\"NEW-NODE\",\"tls\":{\"enabled\":true,\"certificate_path\":\"$W/cert.pem\"}}|" "$W/uci.state"
running_prokop
precheck "named file"
grep -q 'cert.pem' "$STAGE" || fail "the configuration does not name the certificate"
printf 'cert two\n' >"$W/cert.pem"
start "named file"
regenerated "a file the configuration names"
printf 'OK: a file the configuration names -> generated again\n'

# A generation that asked the network (server country lookup) is not reused.
reset_case
running_prokop
TEST_GENERATION_ASKED_NETWORK=1 runtime prepare-config-stage 0 0 1 "" "$STAGE" reusable >/dev/null 2>&1 ||
  fail "the precheck that asked the network failed"
[ ! -e "$STAGE.fingerprint" ] || fail "a generation that asked the network recorded a fingerprint"
start "network"
regenerated "a generation that asked the network"
printf 'OK: a generation that asked the network -> generated again\n'

# ---- (c) a stale or damaged stage ----------------------------------------

damaged_case() {
  local what="$1" mutation="$2"
  reset_case
  running_prokop
  precheck "$what"
  eval "$mutation"
  start "$what"
  regenerated "$what"
  printf 'OK: %s -> generated again\n' "$what"
}
damaged_case "stage changed" "printf ' ' >>'$STAGE'"
damaged_case "stage cut short" "head -c 20 '$STAGE' >'$STAGE.cut' && mv '$STAGE.cut' '$STAGE'"
damaged_case "stage missing" "rm -f '$STAGE'"
damaged_case "fingerprint record damaged" "printf 'garbage' >'$STAGE.fingerprint'"
damaged_case "fingerprint record missing" "rm -f '$STAGE.fingerprint'"
damaged_case "fingerprint of other inputs" \
  "sed -i 's/\"inputs\": *\"[0-9a-f]*\"/\"inputs\":\"00000000000000000000000000000000\"/' '$STAGE.fingerprint'"
damaged_case "stage section cache changed" "printf '{}\n' >'$STAGE.section-cache/main.json'"
damaged_case "stage section cache added" "printf '{}\n' >'$STAGE.section-cache/extra.json'"
damaged_case "stage section cache missing" "rm -rf '${STAGE:?}.section-cache'"

# A stale stage of an earlier restart, put back after other inputs.
reset_case
running_prokop
precheck "stale"
cp -a "$STAGE" "$W/old-stage.json"
cp -a "$STAGE.fingerprint" "$W/old-stage.fingerprint"
cp -a "$STAGE.section-cache" "$W/old-stage.section-cache"
start "stale"
sed -i 's/NEW-NODE/CHANGED-NODE/' "$W/uci.state"
mv "$W/old-stage.json" "$STAGE"
mv "$W/old-stage.fingerprint" "$STAGE.fingerprint"
mv "$W/old-stage.section-cache" "$STAGE.section-cache"
: >"$W/counts"
start "stale"
[ "$(generations)" = 1 ] || fail "a stale stage was published"
grep -q 'CHANGED-NODE' "$CONFIG" || fail "the stale stage's configuration was published"
stage_gone "stale"
printf 'OK: a stale stage -> generated again\n'

# A generation that changed what it read (it built a local list set) is
# not reused; the next one, from the same files, is.
reset_case
printf 'example.org\n' >"$W/local.lst"
printf 'prokop.main.domain_ip_lists=%s\n' "$W/local.lst" >>"$W/uci.state"
precheck "built list set"
[ ! -e "$STAGE.fingerprint" ] || fail "a generation that built its list set recorded a fingerprint"
start "built list set"
regenerated "a generation that changed what it read"
: >"$W/counts"
precheck "list set again"
[ -s "$STAGE.fingerprint" ] || fail "a generation from unchanged files recorded no fingerprint"
start "list set again"
[ "$(generations)" = 1 ] || fail "a stage from unchanged files was generated again"
stage_gone "list set again"
printf 'OK: a generation that changed what it read -> generated again; the next one is reused\n'

printf 'restart_stage_reuse: OK\n'
