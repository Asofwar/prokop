// Runs every route/owner case through autotune/apply.uc plan() and prints
// { case: owner } as JSON.
const fs = require('fs'), path = require('path'), { execFileSync } = require('child_process');
const [lib, work, casesFile] = process.argv.slice(2);
const cases = require(casesFile);
const config = fs.readFileSync(path.join(__dirname, 'prokop.uci'), 'utf8');
fs.writeFileSync(path.join(work, 'driver.uc'), `let apply = require("autotune.apply");\nprint(sprintf("%J\\n", apply.plan(ARGV[0], "192.0.2.53").owner));\n`);
fs.writeFileSync(path.join(work, 'dig'), '#!/bin/sh\nprintf "%s\\n" "$ROUTE_OWNER_DNS"\n', { mode: 0o755 });
const out = {};
for (const [name, rules, opts = {}] of cases) {
  const dir = path.join(work, name); fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'prokop'), config);
  const host = opts.host || 'www.youtube.com';
  fs.writeFileSync(path.join(dir, 'selection.json'), JSON.stringify({ status: 'selected', selected: 'multisplit', confidence: 'high',
    reason: 'test', probes: [], target: { host, ip: '142.250.1.1', resolver: '192.0.2.53' } }));
  const singbox = path.join(dir, 'config.json');
  if (rules) fs.writeFileSync(singbox, JSON.stringify({ route: { final: 'direct-out', rules: rules.map((r) => JSON.parse(JSON.stringify(r))) },
    outbounds: [
      { type: 'direct', tag: 'direct-out' },
      { type: 'vless', tag: 'main-out' },
      { type: 'direct', tag: 'youtube-out', routing_mark: Number(opts.mark || '0x01000001') },
      { type: 'direct', tag: 'discord-out', routing_mark: 0x01000002 },
    ] }));
  const env = { ...process.env, PROKOP_LIB: lib, PROKOP_CONFIG_FILE: path.join(dir, 'prokop'),
    PROKOP_AUTOTUNE_SINGBOX_CONFIG: singbox, PROKOP_AUTOTUNE_DIG: path.join(work, 'dig'),
    ROUTE_OWNER_DNS: opts.dns || '198.18.0.5', PROKOP_AUTOTUNE_STATE_DIR: path.join(dir, 'state'),
    PROKOP_AUTOTUNE_APPLY_STATE: path.join(dir, 'apply-state.json') };
  out[name] = JSON.parse(execFileSync('ucode', ['-L', lib, path.join(work, 'driver.uc'), path.join(dir, 'selection.json')], { env }).toString());
}
console.log(JSON.stringify(out, null, 1));
