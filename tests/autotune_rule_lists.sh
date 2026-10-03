#!/usr/bin/env bash
set -euo pipefail

# Rule-list targets (autotune/lists.uc): a local sing-box rule set measured
# through a deterministic sample of its domains. Keywords and regexes are
# skipped, a domain without an address at the target's resolver gives its
# slot to the next one, pinned domains replace the sample, a binary list is
# decompiled by sing-box, and the members are ordinary targets in groups,
# runs and the state. Nothing is ever applied here.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers/autotune_scheduler/setup.sh
source "$ROOT_DIR/tests/helpers/autotune_scheduler/setup.sh"

# Production DNS (dig +short ... <host> A): FakeIP. The target's resolver
# (dig ... @<resolver> <host> A): an address, except for "noaddr" names.
cat >"$WORK/dig" <<'SH'
#!/bin/sh
case "$4" in
  @*) case "$5" in *noaddr*) ;; *) echo 203.0.113.5 ;; esac ;;
  *) echo 198.18.0.$(printf '%s' "$4" | wc -c) ;;
esac
SH
chmod +x "$WORK/dig"

# sing-box stand-in: "rule-set decompile -o <out> <file>" copies the source
# the test put next to the binary list.
cat >"$WORK/sing-box" <<'SH'
#!/bin/sh
[ "$1 $2 $3" = "rule-set decompile -o" ] || exit 1
echo "$5" >>"$(dirname "$0")/decompile.log"
cp "$5.source" "$4"
SH
chmod +x "$WORK/sing-box"
export PROKOP_AUTOTUNE_SINGBOX_BIN="$WORK/sing-box"

cat >"$WORK/yt-list.json" <<'JSON'
{"version":3,"rules":[
 {"domain_suffix":["youtube.com",".www.youtube.com","m.youtube.com","noaddr.youtube.com","studio.youtube.com"]},
 {"domain":["music.youtube.com","bad_name"]},
 {"domain_keyword":["yt"],"domain_regex":["^r[0-9]+\\.googlevideo\\.com$"]}
]}
JSON
cat >"$WORK/dc-list.srs.source" <<'JSON'
{"version":3,"rules":[{"domain_suffix":["discord.com","cdn.discord.com"]}]}
JSON
printf 'binary' >"$WORK/dc-list.srs"

node - "$WORK/sing-box.json" "$WORK" <<'NODE'
const fs = require('fs');
const [file, work] = process.argv.slice(2);
const c = JSON.parse(fs.readFileSync(file, 'utf8'));
c.route.rule_set = [
  { type: 'local', tag: 'yt-list', format: 'source', path: `${work}/yt-list.json` },
  { type: 'local', tag: 'dc-list', format: 'binary', path: `${work}/dc-list.srs` },
  { type: 'local', tag: 'gone-list', format: 'binary', path: `${work}/gone.srs` },
];
c.route.rules.push({ action: 'route', inbound: 'tproxy-in', rule_set: ['yt-list'], outbound: 'youtube-out' });
c.route.rules.push({ action: 'route', inbound: 'tproxy-in', rule_set: 'dc-list', outbound: 'discord-out' });
c.route.rules.push({ action: 'route', inbound: 'tproxy-in', rule_set: 'gone-list', outbound: 'direct-out' });
fs.writeFileSync(file, JSON.stringify(c));
NODE

check() { node -e 'const r=require(process.argv[1]); const a=require("node:assert/strict"); '"$2" "$1" || fail "$3: $(head -c 1500 "$1")"; }

# ---- validation --------------------------------------------------------------
manager target-set ytl youtube.com 1 "" yt-list >"$WORK/both.json" || true
check "$WORK/both.json" 'a.equal(r.reason, "host_and_rule_set")' "a target is a host or a list"
manager target-set ytl "" 1 "" yt-list 9 >"$WORK/sample.json" || true
check "$WORK/sample.json" 'a.equal(r.reason, "invalid_sample")' "sample 1..8"
manager target-set ytl "" 1 "" 'bad tag' >"$WORK/tag.json" || true
check "$WORK/tag.json" 'a.equal(r.reason, "invalid_rule_set")' "rule set tag"
manager target-set ytl "" 1 "" yt-list "" 'bad_name' >"$WORK/pin.json" || true
check "$WORK/pin.json" 'a.equal(r.reason, "invalid_pin")' "pins are domains"

# ---- sample ---------------------------------------------------------------------
manager target-set ytl "" 1 "" yt-list >"$WORK/set.json"
check "$WORK/set.json" 'a.equal(r.status, "ok"); a.equal(r.target.rule_set, "yt-list"); a.equal(r.target.sample, 3)' "list target saved"
grep -q "option rule_set 'yt-list'" "$PROKOP_CONFIG_FILE" || fail "rule_set option written"
if grep -A4 "autotune_target 'ytl'" "$PROKOP_CONFIG_FILE" | grep -q "option host"; then fail "a list target has no host"; fi

manager status >"$WORK/status.json"
# Sorted: m, music, noaddr, studio, www, youtube.com; slots start at 0, 2, 4;
# noaddr has no address, so its slot takes studio.
check "$WORK/status.json" '
  const t = r.targets.find((x) => x.id === "ytl");
  a.deepEqual(t.list.members, ["m.youtube.com", "studio.youtube.com", "www.youtube.com"]);
  a.equal(t.list.total, 6); a.equal(t.list.skipped, 3); a.equal(t.list.pinned, false);
  a.equal(t.host, null); a.equal(t.last, null);
  const m = r.targets.filter((x) => x.parent === "ytl").map((x) => [x.id, x.host]);
  a.deepEqual(m, [["ytl__1", "m.youtube.com"], ["ytl__2", "studio.youtube.com"], ["ytl__3", "www.youtube.com"]]);
  a.deepEqual(r.lists.map((l) => [l.tag, l.rule]), [["yt-list", "youtube"], ["dc-list", "discord"]]);' "sample and editor lists"

manager groups >"$WORK/groups.json"
check "$WORK/groups.json" '
  a.deepEqual(r.groups.youtube.targets, ["yt", "ytimg", "ytl__1", "ytl__2", "ytl__3"]);' "members join the group of their rule"

# ---- the domains of a list, for choosing pinned domains ---------------------------
manager list-domains yt-list >"$WORK/domains.json"
check "$WORK/domains.json" '
  a.deepEqual(r.domains, ["m.youtube.com", "music.youtube.com", "noaddr.youtube.com", "studio.youtube.com", "www.youtube.com", "youtube.com"]);
  a.equal(r.total, 6); a.equal(r.skipped, 3); a.equal(r.truncated, false);' "list domains"
manager list-domains gone-list >"$WORK/not-dpi.json" || true
check "$WORK/not-dpi.json" 'a.equal(r.reason, "invalid_rule_set")' "only lists of DPI rules are listed"

# ---- a run measures the members -----------------------------------------------------
reset_calls
manager run youtube >"$WORK/run.json"
[ "$(calls)" = 'www.youtube.com i.ytimg.com m.youtube.com studio.youtube.com www.youtube.com ' ] || fail "members are measured: $(calls)"
[ "$(json_get "$PROKOP_AUTOTUNE_STATE_FILE" targets.ytl__1.host)" = '"m.youtube.com"' ] || fail "member summary recorded"
manager target ytl__2 >"$WORK/member.json"
check "$WORK/member.json" 'a.equal(r.status, "ok"); a.equal(r.target.parent, "ytl"); a.equal(r.last.host, "studio.youtube.com")' "member detail"

# ---- pins replace the sample -------------------------------------------------------------
manager target-set ytl "" 1 "" yt-list "" 'music.youtube.com, other.example' >"$WORK/pins.json"
[ "$(grep -c "list pin" "$PROKOP_CONFIG_FILE")" = 2 ] || fail "pins written as a list"
manager status >"$WORK/pinned.json"
check "$WORK/pinned.json" '
  const t = r.targets.find((x) => x.id === "ytl");
  a.deepEqual(t.list.members, ["music.youtube.com"]); a.deepEqual(t.list.missing, ["other.example"]); a.equal(t.list.pinned, true);
  const m = r.targets.find((x) => x.id === "ytl__1");
  a.equal(m.host, "music.youtube.com"); a.equal(m.last, null, "a result for another domain is not shown");' "pinned members"
manager target-set ytl "" 1 "" yt-list 2 >"$WORK/unpin.json"
if grep -q "list pin" "$PROKOP_CONFIG_FILE"; then fail "pins removed when not given"; fi

# ---- a binary list is decompiled, and kept while it does not change ------------------------
manager target-set dcl "" 1 "" dc-list >/dev/null
manager status >"$WORK/binary.json"
check "$WORK/binary.json" 'a.deepEqual(r.targets.find((x) => x.id === "dcl").list.members, ["cdn.discord.com", "discord.com"])' "binary list"
manager status >/dev/null
[ "$(wc -l <"$WORK/decompile.log")" = 1 ] || fail "an unchanged list is not decompiled again"

# ---- a list without a local file is outside ------------------------------------------------
manager target-set gone "" 1 "" gone-list >/dev/null
manager groups >"$WORK/gone.json"
check "$WORK/gone.json" 'a.deepEqual(r.outside.find((x) => x.id === "gone"), { id: "gone", host: "gone-list", reason: "list_file_missing", detail: null })' "missing list"

# ---- a list whose domains have no address: outside, and not asked again at once ----
cat >"$WORK/dead.json" <<'JSON'
{"version":3,"rules":[{"domain_suffix":["noaddr1.youtube.com","noaddr2.youtube.com"]}]}
JSON
node -e 'const f=process.argv[1],c=require(f);c.route.rule_set.push({type:"local",tag:"dead-list",format:"source",path:process.argv[2]});require("fs").writeFileSync(f,JSON.stringify(c))' "$WORK/sing-box.json" "$WORK/dead.json"
manager target-set dead "" 1 "" dead-list >/dev/null
: >"$WORK/dig.log"
sed -i '2i echo "$*" >>"'"$WORK"'/dig.log"' "$WORK/dig"
manager status >"$WORK/dead-status.json"
check "$WORK/dead-status.json" 'a.equal(r.targets.find((x) => x.id === "dead").list.error, "list_domains_unresolved")' "unresolved list"
asked="$(grep -c noaddr "$WORK/dig.log")"
[ "$asked" -gt 0 ] || fail "the resolver was asked about the list"
manager status >/dev/null
[ "$(grep -c noaddr "$WORK/dig.log")" = "$asked" ] || fail "a list that gave nothing is not resolved again on every status"
manager target-remove dead >/dev/null

# ---- a list target becomes a host target, and removal forgets its members -----------------
manager target-remove ytl >/dev/null
node -e 'const s=require(process.argv[1]); if (Object.keys(s.targets).some((k) => k.startsWith("ytl"))) process.exit(1)' "$PROKOP_AUTOTUNE_STATE_FILE" || fail "members forgotten on removal"
manager target-set dcl discord.com >"$WORK/to-host.json"
check "$WORK/to-host.json" 'a.equal(r.target.host, "discord.com")' "list target to host target"
if grep -A5 "autotune_target 'dcl'" "$PROKOP_CONFIG_FILE" | grep -q "rule_set"; then fail "rule_set removed from a host target"; fi

printf 'autotune_rule_lists: PASS\n'
