#!/usr/bin/env bash
set -euo pipefail

# A candidate configuration that is only checked changes nothing the
# running generation reads (LC-8).
#
# 1. prepare-config-stage (a reload's stage, the restart precheck) wrote the
#    candidate's section caches straight into the running section-cache:
#    a candidate that "sing-box check" refused still left its nodes and
#    groups to the dashboard and to the Priority worker of the old
#    sing-box. Now they stay next to the stage until commit-config-stage
#    publishes them, and go with discard-config-stage.
# 2. materialize-config of such a candidate pruned the cached rule-set
#    files the running configuration still references, when the candidate
#    no longer had that rule set: the running sing-box would not start
#    again after a respawn. Now the running configuration's files stay.
#
# singbox/runtime.uc, generator.uc and ruleset_cache.uc run for real;
# sing-box, logger and nft are stand-ins.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; [ ! -s "$W/logger.log" ] || sed 's/^/  log: /' "$W/logger.log" >&2; exit 1; }

mkdir -p "$W/bin" "$W/run/section-cache" "$W/rulesets" "$W/tmp" "$W/cache" "$W/rtcache"
cat >"$W/bin/sing-box" <<'SH'
#!/bin/sh
[ "$1" = version ] && { printf 'sing-box version 1.12.9\n'; exit 0; }
exit 0
SH
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/logger.log"\n' "$W" >"$W/bin/logger"
printf '#!/bin/sh\nexit 1\n' >"$W/bin/nft"
chmod +x "$W/bin/"*
cat >"$W/uci.state" <<UCI
prokop.settings=settings
prokop.settings.config_path=$W/config.json
prokop.settings.dns_server=77.88.8.8
prokop.settings.bootstrap_dns_server=77.88.8.8
prokop.main=section
prokop.main.enabled=1
prokop.main.action=connection
prokop.main.outbound_jsons={"type":"direct","tag":"NEW-NODE"}
UCI
printf '{"running":"old generation"}\n' >"$W/run/section-cache/main.json"
printf '{"running":"old config"}\n' >"$W/config.json"
E() {
  env PATH="$W/bin:$PATH" PROKOP_LIB="$LIB" PROKOP_UCI_STATE_FILE="$W/uci.state" PROKOP_RUNTIME_STATE_DIR="$W/run" \
    TMP_RULESET_FOLDER="$W/rulesets" TMP_SING_BOX_FOLDER="$W/tmp" TMP_SUBSCRIPTION_FOLDER="$W/tmp/subscriptions" \
    PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$W/subcache" PROKOP_RULESET_CACHE_DIR="$W/cache" \
    PROKOP_RULESET_RUNTIME_CACHE_DIR="$W/rtcache" PROKOP_RULESET_RUNTIME_MANIFEST="$W/run/rt.json" \
    PROKOP_PERSISTENT_LIST_CACHE_MIN_FREE_BYTES=0 TMPDIR="$W/tmp" "$@"
}
runtime() { E ucode -L "$LIB" "$LIB/singbox/runtime.uc" "$@"; }

# 1a. A refused candidate.
if PROKOP_SINGBOX_CONFIG_FAIL_PHASE=check runtime prepare-config-stage 0 0 1 "" "$W/refused.json" >/dev/null 2>&1; then
  fail "the injected check failure did not refuse the candidate"
fi
grep -q 'old generation' "$W/run/section-cache/main.json" ||
  fail "a refused candidate rewrote the running section cache: $(cat "$W/run/section-cache/main.json")"
[ -z "$(find "$W/tmp" -name '*.section-cache' 2>/dev/null)" ] || fail "a refused candidate left its section caches"

# 1b. A candidate that passed is staged with its section caches, which only
#     its commit publishes.
stage="$W/stage.json"
runtime prepare-config-stage 0 0 1 "" "$stage" >/dev/null 2>&1 || fail "the candidate was refused"
[ -s "$stage" ] || fail "the candidate was not staged: $(cat "$W/logger.log" 2>/dev/null)"
grep -q 'old generation' "$W/run/section-cache/main.json" || fail "staging rewrote the running section cache"
grep -q 'NEW-NODE' "$stage.section-cache/main.json" || fail "the stage has no section cache of its own"
runtime commit-config-stage "$stage" "$W/backup.json" || fail "the stage was not committed"
grep -q 'NEW-NODE' "$W/run/section-cache/main.json" || fail "the commit did not publish the section cache"
grep -q 'NEW-NODE' "$W/config.json" || fail "the commit did not publish the configuration"
[ ! -e "$stage.section-cache" ] || fail "the published section caches stayed next to the stage"
# A discarded stage takes its section caches along.
runtime prepare-config-stage 0 0 1 "" "$W/stage2.json" >/dev/null 2>&1 || fail "the second candidate was refused"
runtime discard-config-stage "$W/stage2.json" || fail "the stage was not discarded"
[ ! -e "$W/stage2.json.section-cache" ] || fail "a discarded stage left its section caches"

# 2. The rule-set files of the running configuration.
rsc() { E ucode -L "$LIB" "$LIB/singbox/ruleset_cache.uc" "$@"; }
printf '%s\n' '{"route":{"rule_set":[{"type":"remote","tag":"a","format":"source","url":"https://example.org/a.json"}]}}' >"$W/running.json"
rsc materialize-config "$W/running.json" cache-only 2>/dev/null || fail "the running configuration was not materialized"
cached="$W/cache/$(basename "$(ucode -e 'print(json(require("fs").readfile(ARGV[0])).route.rule_set[0].path)' -- "$W/running.json")" | sed 's/^empty-//')"
printf '%s\n' '{"version":2,"rules":[{"domain_suffix":["a.example"]}]}' >"$cached"
printf '%s\n' '{"route":{"rule_set":[{"type":"remote","tag":"a","format":"source","url":"https://example.org/a.json"}]}}' >"$W/running.json"
rsc materialize-config "$W/running.json" cache-only 2>/dev/null || fail "the running configuration was not materialized again"
live="$(ucode -e 'print(json(require("fs").readfile(ARGV[0])).route.rule_set[0].path)' -- "$W/running.json")"
[ "$live" = "$cached" ] || fail "the running configuration does not use the cached rule set: $live"
printf '{"route":{"rule_set":[]}}\n' >"$W/candidate.json"
rsc materialize-config "$W/candidate.json" cache-only "$W/running.json" || fail "the candidate was not materialized"
[ -e "$live" ] || fail "a candidate pruned the rule-set file the running configuration uses"
# Once that candidate runs, the next generation prunes the file.
cp "$W/candidate.json" "$W/next.json"
rsc materialize-config "$W/next.json" cache-only "$W/candidate.json" || fail "the next generation was not materialized"
[ ! -e "$live" ] || fail "a rule-set file no configuration uses was kept"

printf 'config_stage_isolation: OK\n'
