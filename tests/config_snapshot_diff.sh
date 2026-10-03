#!/bin/sh
# The snapshot diff (config_snapshot_diff, History > Changes, the restore
# confirmation) on configurations in the form libuci writes them.
# UC-018: an anonymous section (`config <type>` without a name) is a section
# of its own, addressed as libuci does (@type[n], n counting every section of
# that type in file order), never merged into the named section before it.
# UC-062: a diff longer than the listed rows says so, with the total.
# The reading follows libuci: CRLF line ends, an option followed by a list.
set -eu
ROOT="$(CDPATH="" cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
command -v ucode >/dev/null || { echo 'FAIL: ucode is required' >&2; exit 1; }
command -v node >/dev/null || { echo 'FAIL: node is required' >&2; exit 1; }
# Where the OpenWrt uci CLI exists, every anonymous row is also read back
# through libuci's own addressing.
UCI_BIN="$(command -v uci 2>/dev/null || true)"
[ -n "$UCI_BIN" ] || echo 'NOTE: no uci CLI on PATH, @type[n] keys are not cross-checked with libuci' >&2

node - "$LIB" "$SCRIPT" "$WORK" "$UCI_BIN" <<'JS'
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const assert = require('node:assert/strict');
const [lib, script, work, uci] = process.argv.slice(2);
let run = 0;
function diff(before, after) {
  const dir = `${work}/case${run++}`;
  fs.mkdirSync(dir);
  fs.writeFileSync(`${dir}/before`, before);
  fs.writeFileSync(`${dir}/prokop`, after);
  const rows = JSON.parse(execFileSync('ucode', ['-L', lib, script, 'fixture-diff', `${dir}/before`, `${dir}/prokop`]));
  // libuci reads the same option at the reported key.
  if (uci) {
    for (const row of rows) {
      if (typeof row.section !== 'string' || !row.section.startsWith('@') ||
        typeof row.after !== 'string' || row.after === '***') continue;
      const got = execFileSync(uci, ['-c', dir, 'get', `prokop.${row.section}.${row.option}`]).toString().trim();
      assert.equal(got, row.after, `uci get prokop.${row.section}.${row.option}`);
    }
  }
  return rows;
}
// libuci's export format: `config <type>` for an anonymous section.
const section = (type, name, ...options) =>
  `\nconfig ${type}${name ? ` '${name}'` : ''}\n${options.map((o) => `\t${o}\n`).join('')}`;
const iface = (name, dns) => section('section_interface', null,
  "option section 'Czech'", `option name '${name}'`, `option dns_type '${dns}'`);
const routing = section('section', 'Czech', "option action 'proxy'");
const two = routing + iface('awg0', 'udp') + iface('awg1', 'udp');

// A change in the first of two anonymous items is reported for that item.
assert.deepEqual(diff(two, routing + iface('awg0', 'doh') + iface('awg1', 'udp')), [
  { section: '@section_interface[0]', option: 'dns_type', before: 'udp', after: 'doh' },
]);
// A change in the second one is keyed @type[1], not to the named parent.
assert.deepEqual(diff(two, routing + iface('awg0', 'udp') + iface('awg1', 'dot')), [
  { section: '@section_interface[1]', option: 'dns_type', before: 'udp', after: 'dot' },
]);
// Removing the first item is a change (it was an empty diff: the restore
// preview said "No saved changes" while the restore re-adds the interface).
const removed = diff(two, routing + iface('awg1', 'dot'));
assert.ok(removed.length > 0, 'removing an anonymous section must be visible');
assert.deepEqual(removed.map((row) => row.section).filter((s) => !s.startsWith('@section_interface[')), []);
assert.ok(removed.some((row) => row.section === '@section_interface[1]'));
assert.deepEqual(removed.find((row) => row.section === '@section_interface[0]' && row.option === 'dns_type'),
  { section: '@section_interface[0]', option: 'dns_type', before: 'udp', after: 'dot' });

// List options of two anonymous items stay separate.
const urltest = (...servers) => section('urltest', null, ...servers.map((s) => `list dns_server '${s}'`));
const main = section('section', 'main', "option action 'proxy'");
assert.deepEqual(diff(main + urltest('1.1.1.1') + urltest('8.8.8.8'), main + urltest('8.8.8.8') + urltest('1.1.1.1')), [
  { section: '@urltest[0]', option: 'dns_server', kind: 'list', before: ['1.1.1.1'], after: ['8.8.8.8'] },
  { section: '@urltest[1]', option: 'dns_server', kind: 'list', before: ['8.8.8.8'], after: ['1.1.1.1'] },
]);

// A child option does not hide the named parent's option of the same name.
const child = section('section_interface', null, "option action 'block'");
assert.deepEqual(diff(main + child, section('section', 'main', "option action 'direct'") + child), [
  { section: 'main', option: 'action', before: 'proxy', after: 'direct' },
]);
// Nor the other way round: the child's change is the child's.
assert.deepEqual(diff(main + child, main + section('section_interface', null, "option action 'proxy'")), [
  { section: '@section_interface[0]', option: 'action', before: 'block', after: 'proxy' },
]);

// An anonymous section before any named one is not dropped.
const first = (dns) => section('settings', null, `option dns_type '${dns}'`) + main;
assert.deepEqual(diff(first('udp'), first('doh')), [
  { section: '@settings[0]', option: 'dns_type', before: 'udp', after: 'doh' },
]);

// libuci's @type[n] counts every section of the type, named ones included;
// a named section that appears again is the same section (no new index).
const mixed = (dns) => section('t', 'named', "option action 'a'") + section('t', null, `option dns_type '${dns}'`) +
  section('u', null, "option action 'u'") + section('t', 'named', "option enabled '1'") +
  section('t', null, `option dns_type '${dns}'`);
assert.deepEqual(diff(mixed('udp'), mixed('doh')), [
  { section: '@t[1]', option: 'dns_type', before: 'udp', after: 'doh' },
  { section: '@t[2]', option: 'dns_type', before: 'udp', after: 'doh' },
]);
// An empty name is no name.
const empty = (dns) => `config t ''\n\toption dns_type '${dns}'\n`;
assert.deepEqual(diff(empty('udp'), empty('doh')), [
  { section: '@t[0]', option: 'dns_type', before: 'udp', after: 'doh' },
]);
// Quoted type and name, as hand-written configurations have them.
const quoted = (dns) => `config "section" "main"\n\toption dns_type '${dns}'\nconfig "urltest"\n\toption dns_type '${dns}'\n`;
assert.deepEqual(diff(quoted('udp'), quoted('doh')), [
  { section: 'main', option: 'dns_type', before: 'udp', after: 'doh' },
  { section: '@urltest[0]', option: 'dns_type', before: 'udp', after: 'doh' },
]);
// The file as uci itself rewrites it after `uci set` (the autotune candidate
// is proven against such a rewrite); null without the uci CLI.
function rewritten(text, assignment) {
  if (!uci) return null;
  const dir = `${work}/case${run++}`;
  fs.mkdirSync(`${dir}/save`, { recursive: true });
  fs.writeFileSync(`${dir}/prokop`, text);
  execFileSync(uci, ['-c', dir, '-t', `${dir}/save`, 'set', `prokop.${assignment}`]);
  execFileSync(uci, ['-c', dir, '-t', `${dir}/save`, 'commit', 'prokop']);
  return fs.readFileSync(`${dir}/prokop`, 'utf8');
}
// CRLF line ends, which libuci loads (a \r is a blank to it): named and
// anonymous headers keep their sections, no key or value takes the \r.
const crlf = (text) => text.replace(/\n/g, '\r\n');
const hand = (action, dns) => section('section', 'main', `option action '${action}'`, "option note 'two\nlines'") +
  section('section_interface', null, `option dns_type '${dns}'`, "list dns_server '1.1.1.1'");
assert.deepEqual(diff(crlf(hand('proxy', 'udp')), crlf(hand('direct', 'doh'))), [
  { section: 'main', option: 'action', before: 'proxy', after: 'direct' },
  { section: '@section_interface[0]', option: 'dns_type', before: 'udp', after: 'doh' },
]);
// A CRLF file against its LF form differs in nothing but the change.
assert.deepEqual(diff(crlf(hand('proxy', 'udp')), hand('direct', 'udp')), [
  { section: 'main', option: 'action', before: 'proxy', after: 'direct' },
]);
const lf = rewritten(crlf(hand('proxy', 'udp')), 'main.action=direct');
if (lf != null) {
  // uci ends lines with LF; only the quoted value keeps its \r.
  assert.equal(lf.replace("'two\r\nlines'", '').includes('\r'), false);
  assert.deepEqual(diff(crlf(hand('proxy', 'udp')), lf), [
    { section: 'main', option: 'action', before: 'proxy', after: 'direct' },
  ]);
}
// An option followed by a list of the same name is one list, the option's
// value first, as libuci loads it (uci rewrites it as list lines); a later
// option replaces a list.
const dns = (action, ...lines) => section('settings', 'settings', `option action '${action}'`, ...lines);
const mixedList = dns('proxy', "option dns_server '1.1.1.1'", "list dns_server '8.8.8.8'");
assert.deepEqual(diff(mixedList, dns('proxy', "list dns_server '1.1.1.1'", "list dns_server '8.8.8.8'")), []);
assert.deepEqual(diff(mixedList, dns('proxy', "list dns_server '8.8.8.8'")), [
  { section: 'settings', option: 'dns_server', kind: 'list', before: ['1.1.1.1', '8.8.8.8'], after: ['8.8.8.8'] },
]);
assert.deepEqual(diff(dns('proxy', "list dns_server '1.1.1.1'", "option dns_server '8.8.8.8'"),
  dns('proxy', "option dns_server '8.8.8.8'")), []);
const relisted = rewritten(mixedList, 'settings.action=direct');
if (relisted != null) {
  assert.deepEqual(diff(mixedList, relisted), [
    { section: 'settings', option: 'action', before: 'proxy', after: 'direct' },
  ]);
}

// D-2(a), UC-063: a side without the option is null ("not set"); '***'
// stands only for a value that exists and is hidden.
const settings = (...options) => section('settings', 'settings', ...options);
const secret = "option password 'SECRET_MARKER_s3cr3t'";
assert.deepEqual(diff(settings(), settings(secret)), [
  { section: 'settings', option: 'password', before: null, after: '***' },
]);
assert.deepEqual(diff(settings(secret), settings()), [
  { section: 'settings', option: 'password', before: '***', after: null },
]);
assert.deepEqual(diff(settings(secret), settings("option password 'other'")), [
  { section: 'settings', option: 'password', before: '***', after: '***' },
]);
assert.deepEqual(diff(settings(), settings("option dns_server '1.1.1.1'")), [
  { section: 'settings', option: 'dns_server', before: null, after: '1.1.1.1' },
]);
assert.deepEqual(diff(settings("list subscription_urls 'https://SECRET_MARKER_u@example.com'"), settings()), [
  { section: 'settings', option: 'subscription_urls', kind: 'list', before: ['***'], after: null },
]);
// A whole anonymous section that is gone: every option of it is not set.
assert.deepEqual(diff(main + section('section_interface', null, secret, "option dns_type 'udp'"), main), [
  { section: '@section_interface[0]', option: 'password', before: '***', after: null },
  { section: '@section_interface[0]', option: 'dns_type', before: 'udp', after: null },
]);
// An option statement without a value sets nothing, as libuci loads it:
// alone it is not set, after a value the value stays.
assert.deepEqual(diff(settings(), settings("option password ''")), []);
assert.deepEqual(diff(settings("option dns_type 'udp'"), settings("option dns_type 'udp'", "option dns_type ''")), []);
assert.deepEqual(diff(settings("option dns_type ''"), settings("option dns_type 'doh'")), [
  { section: 'settings', option: 'dns_type', before: null, after: 'doh' },
]);
// Absence reveals no value: nothing of a secret reaches the output.
const all = JSON.stringify([
  diff(settings(), settings(secret)), diff(settings(secret), settings()),
  diff(settings("list subscription_urls 'https://SECRET_MARKER_u@example.com'"), settings()),
]);
assert.equal(all.includes('SECRET_MARKER'), false);

// UC-062: at most 100 rows are listed. A longer diff ends with a marker,
// { truncated: true, total }, total counting every changed option (a list
// option once); the array form stays for its readers.
const many = (count, value) => settings(...Array.from({ length: count }, (_, i) => `option opt${i} '${value}'`));
const hundred = diff(many(100, 'a'), many(100, 'b'));
assert.equal(hundred.length, 100);
assert.equal(hundred.some((row) => 'truncated' in row || 'total' in row), false);
const cut = diff(many(101, 'a'), many(101, 'b'));
assert.equal(cut.length, 101);
assert.deepEqual(cut[100], { truncated: true, total: 101 });
assert.ok(cut.slice(0, 100).every((row) => row.section === 'settings' && /^opt[0-9]+$/.test(row.option)));
const lists = Array.from({ length: 30 }, (_, i) => `list list${i} 'x'`);
const wide = diff(many(250, 'a'), settings(...Array.from({ length: 250 }, (_, i) => `option opt${i} 'b'`), ...lists, ...lists));
assert.equal(wide.length, 101);
assert.deepEqual(wide[100], { truncated: true, total: 280 });
// Unchanged options do not count.
const same = diff(many(150, 'a') + section('section', 'main', "option action 'a'"), many(150, 'a') + section('section', 'main', "option action 'b'"));
assert.deepEqual(same, [{ section: 'main', option: 'action', before: 'a', after: 'b' }]);
// The marker carries a count, nothing of a value.
assert.equal(JSON.stringify(diff(many(120, 'SECRET_MARKER_a'), settings())).includes('SECRET_MARKER'), false);
// Nor does a cut diff of the S1 secret fixture (config_snapshot_diff is
// read-only reachable), its sections made anonymous and repeated past 100.
const fixture = fs.readFileSync(`${lib}/../../../../tests/fixtures/readonly_secrets/prokop`, 'utf8')
  .replace(/^config[ \t]+(\S+)[ \t]+\S+[ \t]*$/gm, 'config $1');
const secrets = diff('', fixture + fixture + fixture);
assert.deepEqual(secrets.at(-1), { truncated: true, total: secrets.at(-1).total });
assert.ok(secrets.at(-1).total > 100);
assert.equal(secrets.length, 101);
assert.equal(JSON.stringify(secrets).includes('SECRET_MARKER'), false);
JS
echo 'config_snapshot_diff: PASS'
