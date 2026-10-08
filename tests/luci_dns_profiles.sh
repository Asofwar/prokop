#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment } = require(process.argv[2]);
(async () => {
  for (const version of ['24.10','25.12']) {
    const env = createEnvironment({version, config:{settings:{'.name':'settings','.type':'settings',yacd_secret_key:'existing-secret',dns_type:'udp',dns_server:['192.0.2.53']}}});
    const settings = await env.openSettings({loaded:true});
    const protocol = settings.option('dns_type'), server = settings.option('dns_server'), profile = settings.option('_dns_profile');
    profile.onchange(null, 'settings', 'cloudflare_doh');
    assert.equal(protocol.formvalue('settings'), 'doh');
    assert.deepEqual(server.formvalue('settings'), ['cloudflare-dns.com/dns-query']);
    protocol.onchange(null, 'settings', 'udp');
    assert.deepEqual(server.formvalue('settings'), ['192.0.2.53'], 'switching protocol must restore the custom server');
    profile.onchange(null, 'settings', 'adguard_doq');
    assert.equal(protocol.formvalue('settings'), 'doq');
    assert.deepEqual(server.formvalue('settings'), ['dns.adguard-dns.com']);
    assert.equal(env.uci.data.settings._dns_profile, undefined, 'profile must not add a second persisted DNS configuration');
  }
  console.log('LuCI DNS profiles preserve custom values across protocols');
})().catch(error => {console.error(error); process.exit(1);});
NODE
