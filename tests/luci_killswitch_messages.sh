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
source="$(sed -n '/^function format(/,/^}/p;/^function codedMessage(/,/^}/p' "$VIEW")"
[ -n "$source" ] || { echo "FAIL: codedMessage not found" >&2; exit 1; }
codes="$(grep -oE '"(config_unreadable|runtime_table_missing|runtime_behind|nft_failed|teardown_incomplete|unexpected|legacy_adopt_failed|legacy_saved_policy|legacy_nft_incomplete|dns_list_failed|dns_warning|uncovered_matchers|client_limited|standby_scope|standby_unreadable|standby_client_limited|excluded_devices|exempt|dnsmasq_conflict|dnsmasq_legacy|service_start_failed)"' "$RUNTIME" | tr -d '"' | sort -u | tr '\n' ' ')"
SOURCE="$source" CODES="$codes" node <<'NODE'
const _ = (s) => `«${s}»`;
const codedMessage = Function('_', `${process.env.SOURCE}; return codedMessage`)(_);
// Codes whose text is the router's own detail (dns_warning, exempt): shown as is.
const detailOnly = new Set(['dns_warning', 'exempt']);
for (const code of process.env.CODES.trim().split(' ')) {
  const text = codedMessage({ code, count: 3, keyword: 1, regex: 2, inverted: 0, file: '/f', table: 'T', product: 'X', detail: 'd' }, 'ENGLISH');
  if (detailOnly.has(code)) {
    if (text !== 'ENGLISH') throw new Error(`${code}: ${text}`);
    continue;
  }
  if (!text.includes('«') || text.includes('ENGLISH') || /\{\w+\}/.test(text)) throw new Error(`${code} is not translated: ${text}`);
}
if (codedMessage({ code: 'from_the_future' }, 'English text') !== 'English text') throw new Error('unknown code must fall back');
if (codedMessage(null, 'English text') !== 'English text') throw new Error('no code must fall back');
NODE
echo "luci_killswitch_messages: OK"
