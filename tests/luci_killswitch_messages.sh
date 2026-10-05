#!/usr/bin/env bash
set -euo pipefail
# FE-10: the kill-switch panel shows the router's errors and warnings in the
# interface language. The router records a code with parameters next to
# each English message (killswitch/runtime.uc); the page translates every
# code it knows through _() and shows the English message only for a code
# it does not know (an older or newer router).
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEW="$ROOT_DIR/luci-app-prokop/htdocs/luci-static/resources/view/prokop/killswitch.js"
RUNTIME="$ROOT_DIR/prokop/files/usr/lib/killswitch/runtime.uc"
source="$(sed -n '/^function format(/,/^}/p;/^const KNOWN_DETAILS = \[/,/^];/p;/^function detailText(/,/^}/p;/^function codedMessage(/,/^}/p' "$VIEW")"
[ -n "$source" ] || { echo "FAIL: codedMessage not found" >&2; exit 1; }
codes="$(grep -oE '"(config_unreadable|runtime_table_missing|runtime_behind|nft_failed|teardown_incomplete|unexpected|legacy_adopt_failed|legacy_saved_policy|legacy_nft_incomplete|dns_list_failed|dns_warning|uncovered_matchers|client_limited|standby_scope|standby_unreadable|standby_client_limited|excluded_devices|exempt|dnsmasq_conflict|dnsmasq_legacy|service_start_failed)"' "$RUNTIME" | tr -d '"' | sort -u | tr '\n' ' ')"
SOURCE="$source" CODES="$codes" node <<'NODE'
const _ = (s) => `«${s}»`;
const codedMessage = Function('_', `${process.env.SOURCE}; return codedMessage`)(_);
for (const code of process.env.CODES.trim().split(' ')) {
  const text = codedMessage({ code, count: 3, keyword: 1, regex: 2, inverted: 0, file: '/f', table: 'T', product: 'X', detail: 'some English detail' }, 'ENGLISH');
  if (!text.includes('«') || text.includes('ENGLISH') || /\{\w+\}/.test(text)) throw new Error(`${code} is not translated: ${text}`);
  // FE-15: an English detail the page does not know is not shown as is.
  if (text.includes('some English detail')) throw new Error(`${code} shows the English detail: ${text}`);
}
// FE-15: the details the router writes are translated with their values.
const details = [
  ['dns_warning', 'dnsmasq is not managed by Prokop (dont_touch_dhcp); protected domains are guarded by nftables and FakeIP only'],
  ['exempt', '4 excluded device addresses of sections that exempt their excluded devices cannot be read; those devices stay blocked through DNS while Prokop is stopped'],
  ['exempt', 'the excluded devices form more than 8 groups with different blocked names, only 8 get their own resolver; 5 device addresses stay blocked through DNS while Prokop is stopped'],
  ['exempt', 'could not remove /tmp/dnsmasq.d/x.conf'],
  ['runtime_behind', 'the configuration changed since Prokop last applied it; reload Prokop first'],
  ['nft_failed', 'nft render failed: unknown error'],
  ['dns_list_failed', 'protected section(s) a, b not routed by the running Prokop yet (subscription not loaded), so their domains are unknown'],
];
for (const [code, detail] of details) {
  const text = codedMessage({ code, detail }, 'ENGLISH');
  // Translated text is marked «…»; nothing of the detail may be left outside.
  if (!text.includes('«') || text.replace(/«[^»]*»/g, '').includes(detail) || text.includes('ENGLISH') || /\{\w+\}/.test(text)) throw new Error(`${code}: ${detail} is not translated: ${text}`);
}
if (!codedMessage({ code: 'exempt', detail: details[2][1] }).includes('5')) throw new Error('the device count is lost');
if (codedMessage({ code: 'from_the_future' }, 'English text') !== 'English text') throw new Error('unknown code must fall back');
if (codedMessage(null, 'English text') !== 'English text') throw new Error('no code must fall back');
NODE
# Every text the page translates has a Russian entry.
PO="$ROOT_DIR/luci-app-prokop/po/ru/prokop.po"
VIEW="$VIEW" PO="$PO" node <<'NODE'
const fs = require('fs');
const view = fs.readFileSync(process.env.VIEW, 'utf8');
const start = view.indexOf('const KNOWN_DETAILS = [');
const end = view.indexOf('function messagesBlock(');
const po = fs.readFileSync(process.env.PO, 'utf8');
const missing = [];
for (const m of view.slice(start, end).matchAll(/_\(\s*"((?:[^"\\]|\\.)*)",?\s*\)/g)) {
  const id = JSON.parse(`"${m[1]}"`);
  if (!po.includes(`msgid ${JSON.stringify(id)}\nmsgstr "`) || po.includes(`msgid ${JSON.stringify(id)}\nmsgstr ""\n`)) missing.push(id);
}
if (missing.length) throw new Error(`no Russian text for: ${missing.join(' | ')}`);
NODE
echo "luci_killswitch_messages: OK"
