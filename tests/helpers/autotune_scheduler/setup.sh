# shellcheck shell=bash
# Shared setup of the autotune scheduler suites (sourced after ROOT_DIR is
# set): a library tree with the real modules and stand-ins for
# autotune/isolation.uc and autotune/apply.uc, two DPI groups (youtube:
# yt + ytimg, discord: dc), a target outside any group, and helpers.
REAL_LIB="$ROOT_DIR/prokop/files/usr/lib"
STUBS="$ROOT_DIR/tests/helpers/autotune_scheduler"
WORK="$(mktemp -d)"
BG_PIDS=()
# A call the uci test shim refused fails the test, even one it tolerated.
cleanup() {
  local rc=$? pid
  for pid in "${BG_PIDS[@]}"; do kill -9 "$pid" 2>/dev/null || true; done
  uci_cli_report || [ "$rc" != 0 ] || rc=1
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
# The manager writes policy and targets through the uci CLI (UC-009).
# shellcheck source=tests/helpers/uci_cli/select.sh
source "$ROOT_DIR/tests/helpers/uci_cli/select.sh"

# A library tree with the real modules and the two stand-ins.
LIB="$WORK/lib"
mkdir -p "$LIB/autotune"
for entry in "$REAL_LIB"/*; do [ "${entry##*/}" = autotune ] || ln -s "$entry" "$LIB/${entry##*/}"; done
for entry in "$REAL_LIB"/autotune/*; do ln -s "$entry" "$LIB/autotune/${entry##*/}"; done
ln -sf "$STUBS/isolation.uc" "$LIB/autotune/isolation.uc"
ln -sf "$STUBS/apply.uc" "$LIB/autotune/apply.uc"

export PROKOP_LIB="$LIB"
export PROKOP_AUTOTUNE_STATE_FILE="$WORK/etc/autotune/state.json"
export PROKOP_AUTOTUNE_LAST_DIR="$WORK/run/last"
export PROKOP_AUTOTUNE_STATE_DIR="$WORK/run/autotune"
export PROKOP_CONFIG_FILE="$WORK/config/prokop"
export PROKOP_AUTOTUNE_SINGBOX_CONFIG="$WORK/sing-box.json"
export PROKOP_AUTOTUNE_DIG="$WORK/dig"
export PROKOP_AUTOTUNE_UCI_SAVEDIR="$WORK/uci-save" PROKOP_AUTOTUNE_TMPDIR="$WORK/tmp"
export PROKOP_HISTORY_FILE="$WORK/etc/history.jsonl" PROKOP_RUNTIME_STATE_DIR="$WORK/run/state"
export PROKOP_CRONTAB_FILE="$WORK/crontab" PROKOP_AUTOTUNE_CRONTAB="$WORK/crontab-cmd"
export STUB_TUNE_DIR="$WORK/tune" STUB_APPLY_STATUS="$WORK/apply-status.json"
mkdir -p "$WORK/config" "$WORK/uci-save" "$WORK/tmp" "$WORK/tune"

manager() { ucode -L "$LIB" "$LIB/autotune/manager.uc" "$@"; }
calls() { if [ -e "$WORK/tune/calls.log" ]; then awk '{print $2}' "$WORK/tune/calls.log" | tr '\n' ' '; fi; }
reset_calls() { rm -f "$WORK/tune/calls.log"; }
json_get() { node -e 'const v=require(process.argv[1]); const r=process.argv[2].split(".").reduce((o,k)=>o==null?o:o[k],v); console.log(r===undefined?"null":JSON.stringify(r))' "$1" "$2"; }
make_due() { node -e 'const f=process.argv[1],s=require(f);s.next_run_at=1;require("fs").writeFileSync(f,JSON.stringify(s)+"\n")' "$PROKOP_AUTOTUNE_STATE_FILE"; }

cat >"$WORK/crontab-cmd" <<SH
#!/bin/sh
cp "\$1" "$WORK/crontab"
SH
chmod +x "$WORK/crontab-cmd"
printf '%s\n' '0 3 * * * /usr/bin/other-job' '# prokop-list-update line stays' >"$WORK/crontab"

cat >"$WORK/config/prokop" <<'CONF'
config settings 'settings'
	list dns_server 'tls://dns.example'
	list dns_server '192.0.2.1'
config section 'youtube'
	option action 'zapret'
	option label 'YouTube'
	option nfqws_opt '--filter-tcp=443 --dpi-desync=multisplit --dpi-desync-split-pos=1,midsld'
config section 'discord'
	option action 'zapret'
	option label 'Discord'
	option nfqws_opt '--filter-tcp=443 --dpi-desync=fake --dpi-desync-ttl=3'
config autotune 'autotune'
	option confirmations '2'
config autotune_target 'yt'
	option host 'www.youtube.com'
	option resolver '192.0.2.53'
config autotune_target 'ytimg'
	option host 'i.ytimg.com'
config autotune_target 'dc'
	option host 'discord.com'
config autotune_target 'plain'
	option host 'example.org'
CONF
cat >"$WORK/sing-box.json" <<'JSON'
{"route":{"final":"direct-out","rules":[
 {"action":"route","inbound":"tproxy-in","domain_suffix":["youtube.com","ytimg.com"],"outbound":"youtube-out"},
 {"action":"route","inbound":"tproxy-in","domain_suffix":["discord.com"],"outbound":"discord-out"}
]},"outbounds":[{"type":"direct","tag":"direct-out"},
 {"type":"direct","tag":"youtube-out","routing_mark":16777217},{"type":"direct","tag":"discord-out","routing_mark":16777218}]}
JSON
cat >"$WORK/dig" <<'SH'
#!/bin/sh
echo 198.18.0.$(printf '%s' "$4" | wc -c)
SH
chmod +x "$WORK/dig"
selected() { # host candidate confidence
  printf '{"status":"selected","selected":"%s","confidence":"%s","reason":"direct_failed_candidate_stable","target":{"host":"%s","ip":"198.18.0.9"},"candidates":[{"id":"%s","stability":"stable","success":5,"attempted":5,"success_ratio":1}]}\n' \
    "$2" "$3" "$1" "$2" >"$WORK/tune/$1.json"
}
selected www.youtube.com fake high
selected i.ytimg.com fake high
selected discord.com multisplit high
