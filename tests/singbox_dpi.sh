#!/usr/bin/env bash
set -euo pipefail

# DPI bypass by sing-box itself: the rule action singbox_dpi (singbox/dpi.uc).
# The rule's traffic leaves through a direct outbound of its own; its route
# rules carry tls_fragment / tls_record_fragment / tls_fragment_fallback_delay
# (sing-box 1.12) and tls_spoof / tls_spoof_method (1.14). No other rule and
# no base rule (sniffing, DNS, service rules) carries them. The validator
# refuses an unusable setting by version, value and the mixed proxy; the
# generator leaves out what the version cannot read instead of failing the
# whole configuration. nft captures the rule's addresses like any DPI rule;
# the site check still decides routes; autotune says it does not tune it.
# With $PROKOP_TEST_SING_BOX (or sing-box on PATH, 1.14 or newer) every
# generated configuration passes "sing-box check".

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# --- singbox/dpi.uc ------------------------------------------------------------------
cat >"$WORK/unit.uc" <<'UC'
let d = require("singbox.dpi");
function check(cond, message) { if (!cond) { warn("FAIL: ", message, "\n"); exit(1); } }
for (let v in [ "example.com", "vk.com", "a-b.c.example.org", "xn--80ak6aa92e.xn--p1ai" ])
    check(d.valid_sni(v), "valid SNI refused: " + v);
for (let v in [ "", "com", "Example.com", "1.2.3.4", "example.com.", ".example.com", "https://x.com", "x.com:443",
        "x.com/p", "-x.com", "x-.com", "x..com", "exa mple.com", "x.123" ])
    check(!d.valid_sni(v), "invalid SNI accepted: " + v);
check(d.fallback_delay_ms("500ms") == 500 && d.fallback_delay_ms("1s") == 1000 && d.fallback_delay_ms("10s") == 10000, "delays");
for (let v in [ "", "0ms", "11s", "500", "1.5s", "1m", "-1ms", " 5ms" ])
    check(d.fallback_delay_ms(v) == null, "invalid delay accepted: " + v);
check(d.version_at_least("1.14.2", [1, 14]) === true && d.version_at_least("v1.13.9", [1, 14]) === false &&
    d.version_at_least("1.14.0-extended-2.7.2", [1, 14]) === true && d.version_at_least("", [1, 14]) === null &&
    d.version_at_least("2.0.0", [1, 14]) === true, "version compare");

let s = (o) => ({ ".name": "r", action: "singbox_dpi", ...o });
let err = (o, v) => d.validation_error(s(o), v);
check(err({ singbox_dpi_fragment: "record" }, "1.12.0") == null, "record on 1.12");
check(err({ singbox_dpi_fragment: "both", singbox_dpi_fragment_fallback_delay: "200ms" }, "") == null, "both on unknown version");
check(err({ singbox_dpi_spoof_sni: "vk.com" }, "1.14.0") == null, "spoof on 1.14");
check(index(err({}, "1.14.2"), "neither TLS fragmentation nor TLS spoof") >= 0, "nothing on");
check(index(err({ singbox_dpi_fragment: "off" }, "1.14.2"), "neither") >= 0, "explicit off");
check(index(err({ singbox_dpi_fragment: "split" }, "1.14.2"), "unknown sing-box TLS fragmentation mode") >= 0, "bad mode");
check(index(err({ singbox_dpi_fragment: "record", singbox_dpi_fragment_fallback_delay: "1s" }, "1.14.2"), "TCP segment fragmentation only") >= 0, "delay on record");
check(index(err({ singbox_dpi_fragment: "tcp", singbox_dpi_fragment_fallback_delay: "1min" }, "1.14.2"), "is invalid") >= 0, "bad delay");
check(index(err({ singbox_dpi_fragment: "tcp" }, "1.11.15"), "needs sing-box 1.12.0") >= 0, "fragment on 1.11");
check(index(err({ singbox_dpi_spoof_sni: "vk.com" }, "1.13.4"), "TLS spoof needs sing-box 1.14.0 or newer, the installed sing-box is 1.13.4") >= 0, "spoof on 1.13");
check(index(err({ singbox_dpi_spoof_sni: "vk.com" }, ""), "version is unknown") >= 0, "spoof on unknown version fails closed");
check(index(err({ singbox_dpi_spoof_sni: "VK.com" }, "1.14.2"), "not a valid host name") >= 0, "bad SNI");
check(index(err({ singbox_dpi_spoof_sni: "vk.com", singbox_dpi_spoof_method: "wrong-everything" }, "1.14.2"), "unknown TLS spoof method") >= 0, "bad method");
check(index(err({ singbox_dpi_fragment: "record", singbox_dpi_spoof_method: "wrong-ack" }, "1.14.2"), "without a TLS spoof domain") >= 0, "method alone");
for (let m in d.SPOOF_METHODS)
    check(err({ singbox_dpi_spoof_sni: "vk.com", singbox_dpi_spoof_method: m }, "1.14.2") == null, "method " + m);

let ro = (o, v) => d.route_options(s(o), v);
let r = ro({ singbox_dpi_fragment: "both", singbox_dpi_fragment_fallback_delay: "300ms", singbox_dpi_spoof_sni: "vk.com" }, "1.14.2");
check(sprintf("%J", r.options) == sprintf("%J", { tls_fragment: true, tls_record_fragment: true, tls_fragment_fallback_delay: "300ms",
    tls_spoof: "vk.com", tls_spoof_method: "wrong-sequence" }) && length(r.warnings) == 0, "both + spoof options: " + sprintf("%J", r));
r = ro({ singbox_dpi_fragment: "record", singbox_dpi_fragment_fallback_delay: "300ms" }, "1.12.0");
check(sprintf("%J", r.options) == sprintf("%J", { tls_record_fragment: true }), "record ignores the delay");
r = ro({ singbox_dpi_fragment: "tcp", singbox_dpi_spoof_sni: "vk.com" }, "1.13.0");
check(sprintf("%J", r.options) == sprintf("%J", { tls_fragment: true }) && length(r.warnings) == 1 &&
    index(r.warnings[0], "TLS spoof needs sing-box 1.14.0") >= 0, "spoof left out on 1.13: " + sprintf("%J", r));
r = ro({ singbox_dpi_spoof_sni: "vk.com" }, "");
check(length(keys(r.options)) == 0 && length(r.warnings) == 1, "spoof left out on an unknown version");
r = ro({ singbox_dpi_fragment: "tcp" }, "1.11.0");
check(length(keys(r.options)) == 0 && length(r.warnings) == 1, "fragment left out on 1.11");
check(d.strategy_label(s({ singbox_dpi_fragment: "record", singbox_dpi_spoof_sni: "vk.com" })) == "record+spoof:wrong-sequence", "label");
print("unit ok\n");
UC
ucode -L "$LIB" "$WORK/unit.uc" >/dev/null || fail "singbox/dpi.uc unit checks"

# --- generator -----------------------------------------------------------------------
cat >"$WORK/fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"],
    "yacd_secret_key": "test-clash-secret" },
  "section": [
    { ".name": "main", ".type": "section", "enabled": "1", "action": "connection",
      "outbound_jsons": ["{\"type\":\"http\",\"tag\":\"test\",\"server\":\"proxy.example\",\"server_port\":8080}"],
      "domain_suffix": ["proxied.example"] },
    { ".name": "yt", ".type": "section", "enabled": "1", "action": "singbox_dpi",
      "singbox_dpi_fragment": "both", "singbox_dpi_fragment_fallback_delay": "300ms",
      "singbox_dpi_spoof_sni": "vk.com", "singbox_dpi_spoof_method": "wrong-ack",
      "domain_suffix": ["youtube.com"], "ip_cidr": ["203.0.113.0/24"], "community_lists": ["youtube"],
      "fully_routed_ips": ["192.168.1.50"] },
    { ".name": "rec", ".type": "section", "enabled": "1", "action": "singbox_dpi",
      "singbox_dpi_fragment": "record", "domain": ["only-record.example"] },
    { ".name": "zap", ".type": "section", "enabled": "1", "action": "zapret", "domain_suffix": ["zapret.example"] },
    { ".name": "direct", ".type": "section", "enabled": "1", "action": "bypass", "domain_suffix": ["direct.example"] },
    { ".name": "off", ".type": "section", "enabled": "0", "action": "singbox_dpi",
      "singbox_dpi_fragment": "tcp", "domain_suffix": ["disabled.example"] }
  ]
}
JSON
generate() {
  local name="$1" version="$2"
  ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture \
    "$WORK/fixture.json" "$WORK/$name.json" 192.0.2.1 0 0 '' "$version" 2>"$WORK/$name.stderr" ||
    fail "generator failed for $name: $(cat "$WORK/$name.stderr")"
}
generate v114 1.14.2
generate v113 1.13.4
generate v112 1.12.0

node - "$WORK" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const dir = process.argv[2];
const load = (n) => JSON.parse(fs.readFileSync(`${dir}/${n}.json`, 'utf8'));
const stderr = (n) => fs.readFileSync(`${dir}/${n}.stderr`, 'utf8');
const TLS = ['tls_fragment', 'tls_record_fragment', 'tls_fragment_fallback_delay', 'tls_spoof', 'tls_spoof_method'];
const tlsOf = (r) => Object.fromEntries(TLS.filter((k) => k in r).map((k) => [k, r[k]]));
const list = (v) => (v == null ? [] : Array.isArray(v) ? v : [v]);

function check(name, ytOptions) {
  const c = load(name);
  const out = c.outbounds.find((o) => o.tag === 'yt-out');
  assert.deepEqual(out, { type: 'direct', tag: 'yt-out' }, `${name}: a plain direct outbound of the rule's own`);
  assert.deepEqual(c.outbounds.find((o) => o.tag === 'rec-out'), { type: 'direct', tag: 'rec-out' });
  assert.ok(!c.outbounds.some((o) => o.tag === 'off-out'), `${name}: a disabled rule has no outbound`);
  for (const r of c.route.rules) {
    const tls = tlsOf(r);
    if (r.outbound === 'yt-out') {
      assert.equal(r.action, 'route', `${name}: a route action (both fragment kinds are refused on route-options)`);
      assert.deepEqual(tls, ytOptions, `${name}: yt rule options ${JSON.stringify(r)}`);
    } else if (r.outbound === 'rec-out') {
      assert.deepEqual(tls, { tls_record_fragment: true }, `${name}: rec rule options`);
    } else {
      assert.deepEqual(tls, {}, `${name}: a rule of another rule or a base rule has no TLS options: ${JSON.stringify(r)}`);
    }
  }
  const yt = c.route.rules.filter((r) => r.outbound === 'yt-out');
  // fully routed device, inline domains + IPs, the rule-set alternative
  assert.equal(yt.length, 3, `${name}: every route rule of the rule carries the options`);
  assert.ok(yt.some((r) => list(r.source_ip_cidr).includes('192.168.1.50')), `${name}: fully routed device`);
  assert.ok(yt.some((r) => list(r.domain_suffix).includes('youtube.com') && list(r.ip_cidr).includes('203.0.113.0/24')));
  assert.ok(yt.some((r) => r.rule_set != null));
  for (const r of yt)
    assert.deepEqual(list(r.inbound).sort(), ['tproxy-in', 'tproxy6-in'], `${name}: tproxy inbounds only`);
  const zap = c.outbounds.find((o) => o.tag === 'zap-out');
  assert.ok(zap.routing_mark > 0, 'the zapret rule keeps its own marked outbound');
  return c;
}
const full = { tls_fragment: true, tls_record_fragment: true, tls_fragment_fallback_delay: '300ms', tls_spoof: 'vk.com', tls_spoof_method: 'wrong-ack' };
check('v114', full);
assert.equal(stderr('v114').includes('not applied'), false, 'no warning on 1.14');
check('v113', { tls_fragment: true, tls_record_fragment: true, tls_fragment_fallback_delay: '300ms' });
assert.match(stderr('v113'), /rule 'yt': TLS spoof needs sing-box 1\.14\.0 or newer; not applied/);
check('v112', { tls_fragment: true, tls_record_fragment: true, tls_fragment_fallback_delay: '300ms' });
NODE

# --- validator ------------------------------------------------------------------------
validate() {
  local name="$1" context="$2"
  ucode -L "$LIB" "$LIB/config/validator.uc" validate-runtime-fixture "$WORK/$name.json" "$context" >"$WORK/$name.val" 2>&1
}
rule_fixture() {
  local name="$1" options="$2"
  cat >"$WORK/$name.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"], "yacd_secret_key": "test-clash-secret" },
  "section": [ { ".name": "r", ".type": "section", "enabled": "1", "action": "singbox_dpi",
    "domain_suffix": ["example.com"]$options } ]
}
JSON
}
accept() {
  rule_fixture "$1" "$2"
  validate "$1" "{\"sing_box_version\":\"$3\"}" || fail "validator refused $1: $(cat "$WORK/$1.val")"
}
refuse() {
  rule_fixture "$1" "$2"
  if validate "$1" "{\"sing_box_version\":\"$3\"}"; then fail "validator accepted $1"; fi
  grep -Fq "$4" "$WORK/$1.val" || fail "$1: expected '$4', got: $(cat "$WORK/$1.val")"
}
accept rec ', "singbox_dpi_fragment": "record"' 1.12.0
accept tcp_delay ', "singbox_dpi_fragment": "tcp", "singbox_dpi_fragment_fallback_delay": "1s"' 1.13.0
accept spoof ', "singbox_dpi_spoof_sni": "vk.com", "singbox_dpi_spoof_method": "wrong-timestamp"' 1.14.0
accept both_spoof ', "singbox_dpi_fragment": "both", "singbox_dpi_spoof_sni": "vk.com"' 1.14.2
refuse nothing '' 1.14.2 "has neither TLS fragmentation nor TLS spoof turned on"
refuse spoof_old ', "singbox_dpi_spoof_sni": "vk.com"' 1.13.4 "TLS spoof needs sing-box 1.14.0 or newer, the installed sing-box is 1.13.4"
refuse spoof_unknown ', "singbox_dpi_spoof_sni": "vk.com"' "" "the installed sing-box version is unknown"
refuse bad_sni ', "singbox_dpi_spoof_sni": "https://vk.com/"' 1.14.2 "is not a valid host name"
refuse bad_method ', "singbox_dpi_spoof_sni": "vk.com", "singbox_dpi_spoof_method": "rst"' 1.14.2 "unknown TLS spoof method"
refuse bad_mode ', "singbox_dpi_fragment": "yes"' 1.14.2 "unknown sing-box TLS fragmentation mode"
refuse bad_delay ', "singbox_dpi_fragment": "both", "singbox_dpi_fragment_fallback_delay": "2 s"' 1.14.2 "fallback delay '2 s' is invalid"
refuse mixed ', "singbox_dpi_fragment": "record", "mixed_proxy_enabled": "1", "mixed_proxy_port": "4000"' 1.14.2 "does not support the mixed proxy inbound"
# The rule cannot carry DNS or downloads for Settings: its options would not
# apply to them.
cat >"$WORK/download.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": ["77.88.8.8"], "bootstrap_dns_server": ["77.88.8.8"], "yacd_secret_key": "test-clash-secret",
    "download_lists_via_proxy": "1", "download_lists_via_proxy_section": "r" },
  "section": [ { ".name": "r", ".type": "section", "enabled": "1", "action": "singbox_dpi",
    "singbox_dpi_fragment": "record", "domain_suffix": ["example.com"] } ]
}
JSON
if validate download '{"sing_box_version":"1.14.2"}'; then fail "lists were allowed through a sing-box DPI rule"; fi

# --- nft captures the rule's addresses like any DPI rule ----------------------------
mkdir -p "$WORK/bin"
cat >"$WORK/bin/nft" <<'NFT'
#!/usr/bin/env bash
{ printf 'nft'; for arg in "$@"; do printf '\t%s' "$arg"; done; printf '\n'; } >> "${NFT_LOG:?}"
NFT
chmod 0755 "$WORK/bin/nft"
cat >"$WORK/nft.json" <<'JSON'
{ "section": [ { ".name": "yt", ".type": "section", "enabled": "1", "action": "singbox_dpi",
  "singbox_dpi_fragment": "record", "ip_cidr": [ "203.0.113.0/24" ] } ] }
JSON
: >"$WORK/nft.log"
NFT_LOG="$WORK/nft.log" PATH="$WORK/bin:$PATH" PROKOP_NFT_SUBNET_CACHE_DIR="$WORK/nft-cache" \
  ucode -L "$LIB" "$LIB/nft/apply.uc" nft-add-section-priority-rules-fixture "$WORK/nft.json" ProkopTable prokop_interfaces localv4 localv6 0x00100000 ||
  fail "nft priority rules failed"
grep -Fq $'priority_rules\tiifname\t@prokop_interfaces\tip\tdaddr\t!=\t@localv4\tip\tdaddr\t@prokop_rule_yt_subnets\tmeta\tmark\tset\t0x00100000\tcounter\taccept' "$WORK/nft.log" ||
  fail "nft does not capture the rule's addresses: $(cat "$WORK/nft.log")"

# --- the site check, the read-only view and autotune -------------------------------
cat >"$WORK/trace.uc" <<UC
let r = require("routing.resolve");
let groups = require("autotune.groups");
let config = json(require("fs").readfile("$WORK/v114.json"));
const SECTIONS = r.parse_config("config section 'yt'\n\toption action 'singbox_dpi'\n\toption singbox_dpi_fragment 'both'\n\toption singbox_dpi_spoof_sni 'vk.com'\n" +
    "config section 'main'\n\toption action 'connection'\n");
let x = r.resolve(config, SECTIONS, r.target("www.youtube.com", "198.18.0.9", { port: 443, source: "192.168.1.60" }));
let other = r.resolve(config, SECTIONS, r.target("www.proxied.example", "198.18.0.10", { port: 443, source: "192.168.1.60" }));
let c = groups.classify({ answers: 1, fakeip: true }, x);
print(sprintf("%J\n", [ x.status, x.outbound, x.action, x.dpi, other.status, other.outbound, c.reason, c.detail ]));
UC
trace="$(ucode -L "$LIB" "$WORK/trace.uc" 2>&1)" || fail "site check failed: $trace"
expected='["decided","yt-out","singbox_dpi",{"provider":"singbox_dpi","strategy":"both+spoof:wrong-sequence","custom":false},"decided","main-out","singbox_dpi_not_supported","yt"]'
[ "$(printf '%s' "$trace" | tr -d ' \n')" = "$expected" ] || fail "site check / autotune: got $trace"

# --- a changed option changes the sing-box signature --------------------------------
sig() { ucode -L "$LIB" "$LIB/service/state.uc" sing-box-signature-body-fixture "$1"; }
sig "$WORK/rec.json" >"$WORK/sig1"
sig "$WORK/tcp_delay.json" >"$WORK/sig2"
grep -Fq 'singbox_dpi_fragment' "$WORK/sig1" || fail "the signature does not carry the DPI options"
cmp -s "$WORK/sig1" "$WORK/sig2" && fail "a changed fragmentation mode did not change the signature"

# --- the LuCI rule form ---------------------------------------------------------------
node - "$ROOT_DIR/luci-app-prokop/htdocs/luci-static/resources/view/prokop/section.js" <<'NODE'
const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
const source = fs.readFileSync(process.argv[2], 'utf8');
const slice = (from, to) => {
  const a = source.indexOf(from), b = source.indexOf(to, a);
  assert(a >= 0 && b > a, `missing ${from}`);
  return source.slice(a, b);
};
const helpers = slice('const SINGBOX_DPI_SPOOF_MIN_VERSION', 'function ensureActionProvidersAvailabilityLoaded(');
const block = slice('// singbox-dpi-form-begin', '// singbox-dpi-form-end');
assert(/"singbox_dpi",\n\];/.test(source), 'singbox_dpi is a routing action (conditions, devices)');
assert(source.includes('option.value("singbox_dpi", _("DPI bypass by sing-box"));'), 'offered in the action list');
const format = function (...args) { let i = 0; return this.replace(/%s/g, () => String(args[i++])); };
const options = {};
let version = '1.13.4';
const saved = {};
const formValues = {};
const ctx = {
  _: (text) => Object.assign(new String(text), { format }),
  UCI_PACKAGE: 'prokop',
  uci: { get: (c, sid, key) => saved[key] ?? null, set: (c, sid, key, value) => { saved[key] = value; } },
  main: { ProkopShellMethods: { getSystemInfo: async () => ({ success: true, data: { sing_box_version: version } }) } },
  form: { ListValue: 'ListValue', Value: 'Value' },
  section: {
    taboption(tab, type, name, title, description) {
      return options[name] = {
        tab, type, name, description, dependencies: [], values: [],
        section: { formvalue: (sid, key) => formValues[key] },
        depends(key, value) { this.dependencies.push(typeof key === 'string' ? { [key]: value } : key); },
        value(key) { this.values.push(key); },
        cfgvalue: (sid) => saved[name],
      };
    },
  },
};
vm.runInNewContext(`${helpers}\nlet o;\n${block}\nthis.reason = singboxDpiSpoofUnavailableReason;`, ctx);
const visible = (name, state) => options[name].dependencies.some((d) =>
  Object.entries(d).every(([k, v]) => (Object.prototype.toString.call(v) === '[object RegExp]' ? v.test(state[k] || '') : state[k] === v)));
assert.deepEqual(Object.keys(options), ['singbox_dpi_fragment', 'singbox_dpi_fragment_fallback_delay',
  'singbox_dpi_spoof_sni', 'singbox_dpi_spoof_method']);
assert.deepEqual(options.singbox_dpi_fragment.values, ['off', 'record', 'tcp', 'both']);
assert.deepEqual(options.singbox_dpi_spoof_method.values,
  ['wrong-sequence', 'wrong-checksum', 'wrong-ack', 'wrong-md5', 'wrong-timestamp']);
assert.equal(options.singbox_dpi_spoof_method.default, 'wrong-sequence');
for (const action of ['connection', 'zapret', 'zapret2', 'byedpi', 'bypass', 'block', 'dns'])
  for (const name of Object.keys(options))
    assert.equal(visible(name, { action, singbox_dpi_fragment: 'tcp', singbox_dpi_spoof_sni: 'vk.com' }), false, `${name} hidden for ${action}`);
assert.equal(visible('singbox_dpi_fragment_fallback_delay', { action: 'singbox_dpi', singbox_dpi_fragment: 'record' }), false);
assert.equal(visible('singbox_dpi_fragment_fallback_delay', { action: 'singbox_dpi', singbox_dpi_fragment: 'both' }), true);
assert.equal(visible('singbox_dpi_spoof_method', { action: 'singbox_dpi', singbox_dpi_spoof_sni: '' }), false);
assert.equal(visible('singbox_dpi_spoof_method', { action: 'singbox_dpi', singbox_dpi_spoof_sni: 'vk.com' }), true);
const frag = options.singbox_dpi_fragment;
assert.notEqual(frag.validate('r', 'off'), true, 'nothing turned on is refused');
formValues.singbox_dpi_spoof_sni = 'vk.com';
assert.equal(frag.validate('r', 'off'), true, 'spoof alone is enough');
const delay = options.singbox_dpi_fragment_fallback_delay;
for (const v of ['', '500ms', '10s']) assert.equal(delay.validate('r', v), true, v);
for (const v of ['0ms', '11s', '1m', '500']) assert.notEqual(delay.validate('r', v), true, v);
(async () => {
  const sni = options.singbox_dpi_spoof_sni;
  await sni.load('r');
  assert.equal(sni.readonly, true, 'TLS spoof disabled on sing-box 1.13');
  assert.match(String(sni.description), /needs sing-box 1\.14\.0 or newer, the installed sing-box is 1\.13\.4/);
  assert.match(String(sni.validate('r', 'vk.com')), /needs sing-box 1\.14\.0/);
  assert.equal(sni.validate('r', ''), true, 'an empty domain is always fine');
  saved.singbox_dpi_spoof_sni = 'vk.com';
  await sni.load('r');
  assert.equal(sni.readonly, null, 'a saved domain stays editable so it can be cleared');
  delete saved.singbox_dpi_spoof_sni;
  // a newer sing-box: a fresh form instance asks again
  version = '1.14.2';
  for (const k of Object.keys(options)) delete options[k];
  vm.runInNewContext(`${helpers}\nlet o;\n${block}`, { ...ctx });
  const sni2 = options.singbox_dpi_spoof_sni;
  await sni2.load('r');
  assert.equal(sni2.readonly, null);
  assert.equal(sni2.validate('r', 'VK.com'), true, 'written in lower case');
  for (const v of ['https://vk.com', 'vk.com:443', '1.2.3.4', 'vk'])
    assert.notEqual(sni2.validate('r', v), true, v);
  sni2.write('r', ' VK.Com ');
  assert.equal(saved.singbox_dpi_spoof_sni, 'vk.com');
})().catch((e) => { console.error(e); process.exit(1); });
NODE

# --- the real sing-box ------------------------------------------------------------------
SING_BOX="${PROKOP_TEST_SING_BOX:-$(command -v sing-box 2>/dev/null || true)}"
if [ -z "$SING_BOX" ] || [ ! -x "$SING_BOX" ]; then
  printf 'singbox_dpi: OK (real sing-box not checked: set PROKOP_TEST_SING_BOX)\n'
  exit 0
fi
real_version="$("$SING_BOX" version | awk 'NR == 1 { print $3 }')"
generate real "$real_version"
"$SING_BOX" check -c "$WORK/real.json" >"$WORK/check.log" 2>&1 || fail "real sing-box $real_version refused the configuration: $(cat "$WORK/check.log")"
case "$real_version" in
  1.1[4-9].*|1.[2-9][0-9].*|[2-9].*)
    grep -Fq '"tls_spoof"' "$WORK/real.json" || fail "sing-box $real_version: TLS spoof was left out"
    # The version gate is real: a route-options action refuses both kinds.
    printf '{"route":{"rules":[{"action":"route-options","domain":"x.example","tls_fragment":true,"tls_record_fragment":true}]}}\n' >"$WORK/ro.json"
    "$SING_BOX" check -c "$WORK/ro.json" >/dev/null 2>&1 && fail "sing-box accepts both kinds on route-options; the route action is not needed"
    ;;
esac
echo "singbox_dpi: OK"
