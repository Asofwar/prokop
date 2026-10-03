#!/usr/bin/env bash
set -euo pipefail

# DPI autotune isolation: production bypass contract and mark flow.
#
# 1. The contract (autotune/contract.uc) accepts the real Prokop setup and
#    refuses every system where the probe-mark bypass is missing, ambiguous,
#    preceded by an unsafe rule or scheduled before the probe chains, where
#    another table, legacy iptables, policy routing or production inbound
#    rules could still touch the probe or its replies.
# 2. The temporary chains (isolation.uc model) give the probe connection the
#    canonical probe mark in a route chain that accepts (so it is re-routed
#    with it) and normalize nfqws-injected packets (desync | probe mark =
#    0x48000000) back to 0x08000000, so production only ever sees that mark.
#    Production output rules are reordered and rewritten: whenever the
#    contract holds, every probe packet ends in the production bypass with
#    0x08000000, is never queued or re-marked by production and is routed by
#    the main table. The previous design and a model without normalization
#    are evaluated on the same rulesets to show they leak exactly where the
#    old rule-order dependency is removed.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PROKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/autotune/isolation.uc" model 172.217.20.163 > "$WORK/model.json"
PROKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/autotune/isolation.uc" model 172.217.20.163 direct > "$WORK/model-direct.json"

ROOT="$ROOT" LIB="$LIB" WORK="$WORK" node <<'JS'
const fs = require('fs');
const path = require('path');
const assert = require('node:assert/strict');
const { execFileSync } = require('child_process');
const { Production, outputPath } = require(path.join(process.env.ROOT, 'tests/helpers/autotune_nft_sim.js'));

const { ROOT, LIB, WORK } = process.env;
const FIXTURE = JSON.parse(fs.readFileSync(path.join(ROOT, 'tests/fixtures/autotune/ruleset.json'), 'utf8')).nftables;
const IPRULES = JSON.parse(fs.readFileSync(path.join(ROOT, 'tests/fixtures/autotune/iprule.json'), 'utf8'));
const MODEL = JSON.parse(fs.readFileSync(path.join(WORK, 'model.json'), 'utf8'));
const MODEL_DIRECT = JSON.parse(fs.readFileSync(path.join(WORK, 'model-direct.json'), 'utf8'));
const TARGET = '172.217.20.163';
const PROBE = 0x08000000, DESYNC = 0x40000000, FAKEIP = 0x04000000;
let checks = 0;
const ok = (name) => { checks++; console.log(`ok ${name}`); };
const clone = (v) => JSON.parse(JSON.stringify(v));

// ---- the model under test ----------------------------------------------
{
  const [premark, output] = MODEL.chains;
  assert.equal(premark.type, 'route'); assert.equal(premark.priority, -152);
  assert.equal(output.type, 'route'); assert.equal(output.priority, -151);
  assert.deepEqual(premark.rules.map((r) => [r.comment, r.mark, r.set_mark, r.verdict]), [['probe_mark', 0, PROBE, 'accept']]);
  assert.deepEqual(output.rules.map((r) => [r.comment, r.mark, r.set_mark, r.verdict]), [
    ['reinjected', DESYNC | PROBE, PROBE, 'return'], ['reinjected_bare', DESYNC, PROBE, 'return'],
    ['probe', PROBE, null, 'queue'], ['unexpected', null, null, 'drop']]);
  ok('model: route chain -152 marks+accepts, -151 normalizes, queues, drops the rest');
}
// The previous design: one chain that set the mark and queued in the same
// rule (no re-route), and returned injected packets unnormalized.
const tuple = MODEL.chains[1].rules[0].tuple;
const LEGACY = { chains: [{ name: 'output', type: 'route', hook: 'output', priority: -151, rules: [
  { comment: 'reinjected', tuple, mark: DESYNC | PROBE, set_mark: null, verdict: 'return' },
  { comment: 'probe', tuple, mark: 0, set_mark: PROBE, verdict: 'queue', queue: 4600 },
  { comment: 'unexpected', tuple, mark: null, set_mark: null, verdict: null }] }] };
// The current model with the normalization removed.
const MUTANT = clone(MODEL);
MUTANT.chains[1].rules[0].set_mark = null;

// ---- ruleset surgery by meaning, never by handle ------------------------
const isRule = (x, chain) => x.rule && x.rule.table === 'ProkopTable' && x.rule.chain === chain;
const rulesOf = (listing, chain) => listing.filter((x) => isRule(x, chain)).map((x) => x.rule);
function setRules(listing, chain, rules) {
  const first = listing.findIndex((x) => isRule(x, chain));
  const rest = listing.filter((x) => !isRule(x, chain));
  const at = first < 0 ? rest.length : rest.slice(0, first).length;
  return [...rest.slice(0, at), ...rules.map((rule) => ({ rule })), ...rest.slice(at)];
}
const has = (rule, pred) => rule.expr.some(pred);
const isBypass = (r) => has(r, (e) => e.match && e.match.left.meta && e.match.left.meta.key === 'mark' && e.match.right === PROBE) && has(r, (e) => 'return' in e);
const isDesyncReturn = (r) => has(r, (e) => e.match && e.match.left['&'] && [DESYNC, 0x20000000].includes(e.match.left['&'][1])) && has(r, (e) => 'return' in e);
const setsMark = (r) => has(r, (e) => e.mangle && e.mangle.key.meta && e.mangle.key.meta.key === 'mark');
const isPriorityJump = (r) => has(r, (e) => e.jump && e.jump.target === 'priority_output_rules');
const isPriorityGuard = (r) => has(r, (e) => e.match && e.match.op === '!=' && e.match.left.meta && e.match.left.meta.key === 'mark') && has(r, (e) => 'return' in e);
const chainOf = (l, table, name, family = 'inet') => l.find((x) => x.chain && x.chain.family === family && x.chain.table === table && x.chain.name === name).chain;

const mo = rulesOf(FIXTURE, 'mangle_output');
assert.equal(mo.filter(isBypass).length, 1, 'fixture has exactly one probe-mark bypass');
assert.ok(mo.some(isDesyncReturn) && mo.some(setsMark) && mo.some(isPriorityJump));
assert.ok(rulesOf(FIXTURE, 'priority_output_rules').some(isPriorityGuard));

const OPTIONS = { target: TARGET, probe_saddr: '203.0.113.10', reply_dev: 'pppoe-wan',
  sets: { prokop_interfaces: ['br-lan'] }, legacy_tables: [], uids: [0, 2147483647] };
function contract(listing, ipRules = IPRULES, options = {}) {
  fs.writeFileSync(path.join(WORK, 'ruleset.json'), JSON.stringify({ nftables: listing }));
  fs.writeFileSync(path.join(WORK, 'context.json'), JSON.stringify({ ip_rules: ipRules, options: { ...OPTIONS, ...options } }));
  let out;
  try { out = execFileSync('ucode', ['-L', LIB, path.join(LIB, 'autotune/contract.uc'), 'evaluate',
    path.join(WORK, 'ruleset.json'), path.join(WORK, 'context.json')], { encoding: 'utf8' }); }
  catch (e) { out = e.stdout; }
  return JSON.parse(out);
}

// ---- mark flow ---------------------------------------------------------
// The target is a proxied destination in every production classifier: without
// isolation production would mark it for FakeIP/TPROXY.
const SETS = {
  localv4: ['0.0.0.0/8', '10.0.0.0/8', '127.0.0.0/8', '169.254.0.0/16', '172.16.0.0/12', '192.168.0.0/16', '224.0.0.0/4', '240.0.0.0/4'],
  prokop_subnets: [`${TARGET}/32`], prokop_rule_main_subnets: [`${TARGET}/32`],
  prokop_ports: [443], prokop_ip_ports: [[TARGET, 443]],
};
const base = { daddr: TARGET, saddr: '203.0.113.10', l4proto: 'tcp', dport: 443, oifname: 'pppoe-wan' };
const packets = {
  probe: { ...base, sport: 61000, mark: 0 },
  injected: { ...base, sport: 61000, mark: DESYNC | PROBE },
  injected_bare: { ...base, sport: 61001, mark: DESYNC },
};
function flow(listing, pkt, model = MODEL, ipRules = IPRULES) {
  return outputPath({ model, production: new Production(listing, SETS), ipRules, pkt });
}
const leaks = (r) => r.dropped === null && (r.productionQueue !== null || (r.finalMark & FAKEIP) === FAKEIP ||
  r.path.some((p) => p.action === 'set_mark' && !p.chain.startsWith('ProkopAutotuneProbe')) || r.route !== 'main');

function assertIsolated(listing, label, ipRules = IPRULES) {
  for (const [name, pkt] of Object.entries(packets)) {
    const r = flow(listing, pkt, MODEL, ipRules);
    const where = `${label}/${name}`;
    assert.equal(r.dropped, null, `${where}: dropped`);
    assert.equal(r.markAfterProbe, PROBE, `${where}: probe chains must hand over 0x08000000`);
    assert.equal(r.routeMark, PROBE, `${where}: routed with mark ${r.routeMark.toString(16)}`);
    assert.equal(r.finalMark, PROBE, `${where}: final mark ${r.finalMark.toString(16)}`);
    assert.equal(r.productionQueue, null, `${where}: production queue`);
    assert.ok(!r.path.some((p) => p.action === 'set_mark' && !p.chain.startsWith('ProkopAutotuneProbe')), `${where}: production re-marked the probe`);
    assert.ok(r.productionTerminal && isBypass(r.productionTerminal.rule), `${where}: did not end in the production bypass`);
    assert.equal(r.route, 'main', `${where}: policy route ${r.route}`);
    assert.ok(!r.path.some((p) => p.target === 'priority_output_rules'), `${where}: reached priority_output_rules`);
    assert.ok(!r.path.some((p) => p.rule && isDesyncReturn(p.rule)), `${where}: relied on the desync return rule`);
    if (name === 'probe') assert.equal(r.probeQueue, 4600, `${where}: candidate queue`);
    else assert.equal(r.probeQueue, null, `${where}: injected packet queued again`);
  }
}

// P0: the real Prokop output path.
assert.equal(contract(FIXTURE).ok, true, JSON.stringify(contract(FIXTURE).violations));
assertIsolated(FIXTURE, 'P0');
{
  const r = flow(FIXTURE, packets.injected);
  assert.equal(r.initialMark, 0x48000000);
  assert.deepEqual([r.path[0].comment, r.path[0].mark], ['reinjected', PROBE]);
  ok('injected 0x48000000 normalized to 0x08000000, production bypass reached');
}
{
  const r = outputPath({ model: MODEL_DIRECT, production: new Production(FIXTURE, SETS), ipRules: IPRULES, pkt: packets.probe });
  assert.equal(r.probeQueue, null); assert.equal(r.finalMark, PROBE); assert.equal(r.routeMark, PROBE); assert.equal(r.route, 'main');
  assert.ok(isBypass(r.productionTerminal.rule));
  ok('direct control candidate reaches the bypass unqueued');
}
{
  const r = flow(FIXTURE, { ...packets.probe, mark: 0x01000001 });
  assert.equal(r.dropped, 'probe:output');
  const outside = flow(FIXTURE, { ...packets.injected, sport: 50000 });
  assert.ok(!outside.path.some((p) => p.chain.startsWith('ProkopAutotuneProbe')), 'flow outside the tuple untouched');
  ok('unexpected tuple packets dropped; flows outside the tuple untouched');
}
ok('P0 real ruleset: contract ok, isolated');

// Permutations of everything after the bypass (production rule order is not
// part of the contract). For each: whether the legacy design / the model
// without normalization leaks the injected packet.
const tailOf = (l) => { const rs = rulesOf(l, 'mangle_output'); const cut = rs.findIndex(isBypass) + 1; return [rs.slice(0, cut), rs.slice(cut)]; };
const variants = {
  P1_no_desync_return: [(l) => setRules(l, 'mangle_output', rulesOf(l, 'mangle_output').filter((r) => !isDesyncReturn(r))), true],
  P2_fakeip_before_desync: [(l) => { const [head, tail] = tailOf(l); return setRules(l, 'mangle_output', [...head, ...tail.filter(setsMark), ...tail.filter((r) => !setsMark(r))]); }, true],
  P3_desync_last_priority_unguarded: [(l) => {
    const [head, tail] = tailOf(l);
    const rest = tail.filter((r) => !isPriorityJump(r) && !isDesyncReturn(r));
    const out = setRules(l, 'mangle_output', [...head, ...rest, ...tail.filter(isPriorityJump), ...tail.filter(isDesyncReturn)]);
    return setRules(out, 'priority_output_rules', rulesOf(out, 'priority_output_rules').filter((r) => !isPriorityGuard(r)));
  }, true],
  P4_reversed_tail: [(l) => { const [head, tail] = tailOf(l); return setRules(l, 'mangle_output', [...head, ...tail.reverse()]); }, true],
  P5_masked_bypass_first: [(l) => {
    const masked = { family: 'inet', table: 'ProkopTable', chain: 'mangle_output', handle: 9001,
      expr: [{ match: { op: '==', left: { '&': [{ meta: { key: 'mark' } }, 0xff000000] }, right: PROBE } }, { counter: { packets: 0, bytes: 0 } }, { return: null }] };
    return setRules(l, 'mangle_output', [masked, ...rulesOf(l, 'mangle_output').filter((r) => !isBypass(r))]);
  }, false],
  P6_old_route_removed: [(l) => {
    const out = setRules(l, 'mangle_output', rulesOf(l, 'mangle_output').filter((r) => !isDesyncReturn(r)));
    return setRules(out, 'priority_output_rules', rulesOf(out, 'priority_output_rules').filter((r) => !isPriorityGuard(r)));
  }, true],
};
const isMaskedBypass = (r) => has(r, (e) => e.match && e.match.left['&'] && e.match.left['&'][1] === 0xff000000 && e.match.right === PROBE);
assert.equal(leaks(flow(FIXTURE, packets.injected, LEGACY)), false, 'legacy survives the real order');
assert.equal(leaks(flow(FIXTURE, packets.injected, MUTANT)), false, 'mutant survives the real order');
for (const [name, [mutate, oldLeaks]] of Object.entries(variants)) {
  const listing = mutate(clone(FIXTURE));
  const c = contract(listing);
  assert.equal(c.ok, true, `${name}: ${JSON.stringify(c.violations)}`);
  if (name === 'P5_masked_bypass_first') {
    for (const pkt of Object.values(packets)) {
      const r = flow(listing, pkt);
      assert.equal(r.finalMark, PROBE); assert.equal(r.productionQueue, null); assert.equal(r.route, 'main');
      assert.ok(isMaskedBypass(r.productionTerminal.rule));
    }
  }
  else assertIsolated(listing, name);
  assert.equal(leaks(flow(listing, packets.injected, LEGACY)), oldLeaks, `${name}: legacy leak expectation`);
  assert.equal(leaks(flow(listing, packets.injected, MUTANT)), oldLeaks, `${name}: unnormalized model leak expectation`);
  ok(`${name}: contract ok, isolated; old design ${oldLeaks ? 'leaks' : 'survives'}`);
}
{
  const legacy = flow(variants.P1_no_desync_return[0](clone(FIXTURE)), packets.injected, LEGACY);
  assert.equal(legacy.finalMark & FAKEIP, FAKEIP); assert.equal(legacy.route, 'prokop');
  ok('without handle-117 semantics the old design hands injected packets to FakeIP / table prokop');
}
// Routing: a policy rule that sends unmarked traffic elsewhere. The old design
// queued the original without re-routing (mark 0 route); the new one re-routes
// every probe packet with the probe mark before the queue.
{
  const tunnel = [...IPRULES, { priority: 90, src: 'all', not: null, fwmark: '0x8000000', fwmask: '0x8000000', table: '100' }];
  assert.equal(contract(FIXTURE, tunnel).ok, true);
  assertIsolated(FIXTURE, 'R_not_probe_mark_to_tunnel', tunnel);
  const legacy = flow(FIXTURE, packets.probe, LEGACY, tunnel);
  assert.equal(legacy.probeQueue, 4600); assert.equal(legacy.routeMark, 0); assert.equal(legacy.route, '100');
  ok('queued probe packets are re-routed with the probe mark (old design kept the mark-0 route)');
}

// ---- contract refusals ---------------------------------------------------
const bypassIdx = (l) => l.findIndex((x) => isRule(x, 'mangle_output') && isBypass(x.rule));
const addChain = (l, family, table, name, hook, prio, rules, extra = {}) => [...l,
  ...(l.some((x) => x.table && x.table.family === family && x.table.name === table) ? [] : [{ table: { family, name: table, handle: 77 } }]),
  { chain: { family, table, name, handle: 700, type: extra.type || 'filter', hook, prio, policy: extra.policy || 'accept' } },
  ...rules.map((expr, i) => ({ rule: { family, table, chain: name, handle: 701 + i, expr } }))];
const markSet = (value) => ({ mangle: { key: { meta: { key: 'mark' } }, value } });
const refusals = {
  N1_bypass_removed: [(l) => l.filter((x) => !(isRule(x, 'mangle_output') && isBypass(x.rule))), 'bypass_rule_missing'],
  N2_fakeip_before_bypass: [(l) => { const rs = rulesOf(l, 'mangle_output'); const f = rs.find(setsMark); return setRules(l, 'mangle_output', [f, ...rs.filter((r) => r !== f)]); }, 'unsafe_rule_before_bypass'],
  N3_jump_before_bypass: [(l) => { const rs = rulesOf(l, 'mangle_output'); const j = rs.find(isPriorityJump); return setRules(l, 'mangle_output', [j, ...rs.filter((r) => r !== j)]); }, 'unsafe_rule_before_bypass'],
  N4_bypass_not_universal: [(l) => { l[bypassIdx(l)].rule.expr.unshift({ match: { op: '==', left: { payload: { protocol: 'ip', field: 'daddr' } }, right: '198.51.100.1' } }); return l; }, 'bypass_rule_missing'],
  N5_bypass_negated: [(l) => { l[bypassIdx(l)].rule.expr[0].match.op = '!='; return l; }, 'bypass_rule_missing'],
  N6_bypass_other_mark: [(l) => { l[bypassIdx(l)].rule.expr[0].match.right = 0x08000001; return l; }, 'bypass_rule_missing'],
  N7_production_before_probe: [(l) => { chainOf(l, 'ProkopTable', 'mangle_output').prio = -152; return l; }, 'production_chain_not_after_probe'],
  N8_production_same_priority: [(l) => { chainOf(l, 'ProkopTable', 'mangle_output').prio = -151; return l; }, 'production_chain_not_after_probe'],
  N8b_production_priority_unknown: [(l) => { delete chainOf(l, 'ProkopTable', 'mangle_output').prio; return l; }, 'production_chain_priority_unknown'],
  N8c_production_policy_drop: [(l) => { chainOf(l, 'ProkopTable', 'mangle_output').policy = 'drop'; return l; }, 'production_chain_policy'],
  N9_extra_production_postrouting: [(l) => addChain(l, 'inet', 'ProkopTable', 'late_post', 'postrouting', 0, [[markSet(FAKEIP)]]), 'bypass_rule_missing'],
  N9b_extra_production_postrouting_marks_first: [(l) => addChain(l, 'inet', 'ProkopTable', 'late_post', 'postrouting', 0,
    [[markSet(FAKEIP)], [{ match: { op: '==', left: { meta: { key: 'mark' } }, right: PROBE } }, { return: null }]]), 'unsafe_rule_before_bypass'],
  N10_production_absent: [(l) => l.filter((x) => !((x.table && x.table.name === 'ProkopTable') || ['chain', 'rule', 'set'].some((k) => x[k] && x[k].table === 'ProkopTable'))), 'production_table_absent'],
  N11_production_output_absent: [(l) => l.filter((x) => !((x.chain && x.chain.table === 'ProkopTable' && x.chain.name === 'mangle_output') || isRule(x, 'mangle_output'))), 'production_output_chain_absent'],
  N12_foreign_early_marker: [(l) => addChain(l, 'inet', 'other', 'out', 'output', -200, [[markSet(1)]], { type: 'route' }), 'foreign_chain_unsafe'],
  N13_foreign_late_queue_via_jump: [(l) => [...l,
    { chain: { family: 'inet', table: 'fw4', name: 'hidden', handle: 998 } },
    { rule: { family: 'inet', table: 'fw4', chain: 'hidden', handle: 999, expr: [{ queue: { num: 7 } }] } },
    { rule: { family: 'inet', table: 'fw4', chain: 'mangle_output', handle: 997, expr: [{ jump: { target: 'hidden' } }] } }], 'foreign_chain_unsafe'],
  N14_foreign_opaque_vmap: [(l) => [...l, { rule: { family: 'inet', table: 'fw4', chain: 'mangle_output', handle: 996, expr: [{ vmap: { key: { meta: { key: 'mark' } }, data: '@marks' } }] } }], 'foreign_chain_unsafe'],
  N15_foreign_ct_mark: [(l) => [...l, { rule: { family: 'inet', table: 'fw4', chain: 'mangle_postrouting', handle: 995, expr: [{ mangle: { key: { ct: { key: 'mark' } }, value: 1 } }] } }], 'foreign_chain_unsafe'],
  N16_foreign_unresolved_jump: [(l) => [...l, { rule: { family: 'inet', table: 'fw4', chain: 'mangle_output', handle: 994, expr: [{ jump: { target: 'missing' } }] } }], 'foreign_chain_unresolved'],
  N17_foreign_unknown_statement: [(l) => [...l, { rule: { family: 'inet', table: 'fw4', chain: 'raw_output', handle: 993, expr: [{ xt: { type: 'target', name: 'MARK' } }] } }], 'foreign_chain_unsafe'],
  N18_foreign_daddr_rewrite: [(l) => addChain(l, 'inet', 'other', 'out', 'output', -100, [[{ mangle: { key: { payload: { protocol: 'ip', field: 'daddr' } }, value: '198.18.0.1' } }]], { type: 'route' }), 'foreign_chain_unsafe'],
  N19_foreign_dport_rewrite: [(l) => addChain(l, 'inet', 'other', 'post', 'postrouting', 0, [[{ mangle: { key: { payload: { protocol: 'th', field: 'dport' } }, value: 1602 } }]]), 'foreign_chain_unsafe'],
  N20_same_name_other_family: [(l) => addChain(l, 'ip', 'ProkopTable', 'out', 'output', -140, [[markSet(FAKEIP)]], { type: 'route' }), 'foreign_chain_unsafe'],
  N21_probe_name_other_family: [(l) => addChain(l, 'ip', 'ProkopAutotuneProbe', 'out', 'output', -140, [[{ queue: { num: 4000 } }]], { type: 'route' }), 'foreign_chain_unsafe'],
  N22_reply_path_ungated_tproxy: [(l) => [...l, { rule: { family: 'inet', table: 'ProkopTable', chain: 'proxy', handle: 990,
    expr: [{ match: { op: '==', left: { meta: { key: 'l4proto' } }, right: 'tcp' } }, { tproxy: { family: 'ip', port: 1602 } }] } }], 'reply_path_unsafe'],
  N23_reply_path_wan_in_interfaces: [(l) => l, 'reply_path_unsafe', { sets: { prokop_interfaces: ['br-lan', 'pppoe-wan'] } }],
  N24_reply_path_set_unknown: [(l) => l, 'reply_path_unsafe', { sets: {} }],
  N25_legacy_iptables: [(l) => l, 'legacy_iptables_present', { legacy_tables: ['mangle'] }],
  N26_foreign_reply_queue: [(l) => addChain(l, 'inet', 'other', 'pre', 'prerouting', -200,
    [[{ match: { op: '==', left: { payload: { protocol: 'tcp', field: 'sport' } }, right: 443 } }, { queue: { num: 300 } }]]), 'foreign_reply_unsafe'],
  N27_foreign_reply_fakeip_mark: [(l) => addChain(l, 'inet', 'other', 'in', 'input', 0, [[markSet(FAKEIP)]]), 'foreign_reply_unsafe'],
  N28_reply_statement_before_gate: [(l) => [...l, { rule: { family: 'inet', table: 'ProkopTable', chain: 'mangle', handle: 989,
    expr: [markSet(FAKEIP), { match: { op: '==', left: { meta: { key: 'iifname' } }, right: 'br-lan' } }, { counter: { packets: 0, bytes: 0 } }] } }], 'reply_path_unsafe'],
  N29_reply_wildcard_interface: [(l) => l, 'reply_path_unsafe', { sets: { prokop_interfaces: ['br-lan', 'ppp*'] } }],
  N30_foreign_probe_mark_unconfined: [(l) => addChain(l, 'inet', 'other', 'out', 'output', -200, [[markSet(PROBE)]], { type: 'route' }), 'foreign_chain_unsafe'],
  N31_port_forward_covers_probe_ports: [(l) => addChain(l, 'inet', 'other', 'dnat', 'prerouting', -100,
    [[{ match: { op: '==', left: { meta: { key: 'iifname' } }, right: 'pppoe-wan' } },
      { match: { op: '==', left: { payload: { protocol: 'tcp', field: 'dport' } }, right: { range: [60000, 62000] } } },
      { dnat: { family: 'ip', addr: '192.168.1.10' } }]], { type: 'nat' }), 'foreign_reply_unsafe'],
};
for (const [name, [mutate, code, options]] of Object.entries(refusals)) {
  const c = contract(mutate(clone(FIXTURE)), IPRULES, options || {});
  assert.equal(c.ok, false, `${name} accepted`);
  assert.equal(c.reason, 'isolation_unavailable');
  assert.ok(c.violations.some((v) => v.code === code), `${name}: ${JSON.stringify(c.violations)}`);
  ok(`${name}: refused (${code})`);
}

// Accepted variants that must not be false refusals.
const accepted = {
  A1_torrserver_direct_sets_probe_mark: (l) => addChain(l, 'inet', 'ProkopTorrServerDirect', 'output', 'output', -151,
    [[{ match: { op: '==', left: { socket: { key: 'cgroupv2', level: 2 } }, right: 'services/torrserver' } }, markSet(PROBE), { counter: { packets: 0, bytes: 0 } }]], { type: 'route' }),
  A2_production_postrouting_early_with_bypass: (l) => addChain(l, 'inet', 'ProkopTable', 'post', 'postrouting', -300,
    [[{ match: { op: '==', left: { meta: { key: 'mark' } }, right: PROBE } }, { return: null }], [markSet(FAKEIP)]]),
  A3_foreign_dscp_and_drop: (l) => addChain(l, 'inet', 'other', 'post', 'postrouting', 0,
    [[{ mangle: { key: { payload: { protocol: 'ip', field: 'dscp' } }, value: 'cs1' } }], [{ match: { op: '==', left: { payload: { protocol: 'tcp', field: 'dport' } }, right: 25 } }, { drop: null }]]),
  A4_port_forward_elsewhere: (l) => addChain(l, 'inet', 'other', 'dnat', 'prerouting', -100,
    [[{ match: { op: '==', left: { meta: { key: 'iifname' } }, right: 'pppoe-wan' } },
      { match: { op: '==', left: { payload: { protocol: 'tcp', field: 'dport' } }, right: { set: [8443, { range: [50000, 50100] }] } } },
      { dnat: { family: 'ip', addr: '192.168.1.10' } }]], { type: 'nat' }),
  A5_reply_gated_by_udp: (l) => addChain(l, 'inet', 'other', 'pre', 'prerouting', -200,
    [[{ match: { op: '==', left: { meta: { key: 'l4proto' } }, right: 'udp' } }, { queue: { num: 300 } }]]),
};
for (const [name, mutate] of Object.entries(accepted)) {
  const c = contract(mutate(clone(FIXTURE)));
  assert.equal(c.ok, true, `${name}: ${JSON.stringify(c.violations)}`);
  ok(`${name}: accepted`);
}
{
  const c = contract(accepted.A3_foreign_dscp_and_drop(clone(FIXTURE)));
  assert.ok(c.caveats.some((x) => x.includes('other/post') && x.includes('drop')), JSON.stringify(c.caveats));
  ok('foreign drop on the output path reported as a caveat');
}

// Policy routing.
const rule = (extra) => [...IPRULES, { priority: 90, src: 'all', ...extra }];
const ipCases = {
  R1_fwmark_selects_probe: [rule({ fwmark: '0x8000000', fwmask: '0x8000000', table: '200' }), false],
  R2_exact_fwmark: [rule({ fwmark: '0x8000000', table: 'prokop' }), false],
  R3_negated_fwmark: [rule({ not: null, fwmark: '0x1', fwmask: '0x1', table: 'prokop' }), false],
  R4_fwmark_blackhole: [rule({ fwmark: '0x8000000', action: 'blackhole' }), false],
  R5_fwmark_to_main_ok: [rule({ fwmark: '0x8000000', fwmask: '0x8000000', table: 'main' }), true],
  R6_unrelated_fwmark_ok: [rule({ fwmark: '0x10000', fwmask: '0xff0000', table: '52' }), true],
  R7_value_bits_outside_mask: [rule({ fwmark: '0xc000000', fwmask: '0x8000000', table: '100' }), false],
  R8_not_with_other_selector: [rule({ not: null, fwmark: '0x8000000', ipproto: 'udp', table: '100' }), false],
  R9_ipproto_dport: [rule({ ipproto: 'tcp', dport: 443, table: '100' }), false],
  R10_uidrange_root: [rule({ uidrange: '0-0', table: '100' }), false],
  R11_sport_range: [rule({ sport: '61000-61031', table: 'prokop' }), false],
  R12_to_target: [rule({ dst: '172.217.0.0', dstlen: 16, table: 'prokop' }), false],
  R13_to_other_ok: [rule({ dst: '10.0.0.0', dstlen: 8, table: '100' }), true],
  R14_from_wan_address: [rule({ src: '203.0.113.10', srclen: 32, table: '100' }), false],
  R15_iif_lan_ok: [rule({ iif: 'br-lan', table: '100' }), true],
  R16_udp_only_ok: [rule({ ipproto: 'udp', table: '100' }), true],
  R17_unknown_selector: [rule({ tun_id: 5, table: '100' }), false],
  R18_inverted_uid_root_only: [rule({ not: null, uid_start: 0, uid_end: 0, table: '100' }), false],
  R19_inverted_sport_partial: [rule({ not: null, sport: '61000-61010', table: '100' }), false],
  R20_inverted_all_covering_ok: [rule({ not: null, ipproto: 'tcp', table: '100' }), true],
  R21_l3mdev_ok: [[...IPRULES, { priority: 1000, src: 'all', l3mdev: null }], true],
  R22_suppress_prefixlen_main_ok: [rule({ table: 'main', suppress_prefixlen: 0 }), true],
  R23_tos_ok: [rule({ tos: '0x10', table: '100' }), true],
  R24_nop_ok: [rule({ nop: null }), true],
  R25_blackhole_desync_first_lookup: [rule({ fwmark: '0x40000000', fwmask: '0x40000000', action: 'blackhole' }), false],
  R26_blackhole_unmarked_first_lookup: [rule({ not: null, fwmark: '0x8000000', fwmask: '0x8000000', action: 'unreachable' }), false],
  R27_desync_mark_to_table_ok: [rule({ fwmark: '0x40000000', fwmask: '0x40000000', table: '100' }), true],
};
for (const [name, [rules, expected]] of Object.entries(ipCases)) {
  const c = contract(FIXTURE, rules);
  assert.equal(c.ok, expected, `${name}: ${JSON.stringify(c.violations)}`);
  if (!expected) assert.ok(c.violations.some((v) => v.code.startsWith('policy_route_')));
  ok(`${name}: ${expected ? 'accepted' : 'refused'}`);
}
{
  const c = contract(FIXTURE, 'garbage');
  assert.equal(c.ok, false); assert.ok(c.violations.some((v) => v.code === 'ip_rules_unavailable'));
  ok('policy rules unavailable: refused');
}
{
  const c = contract(FIXTURE, IPRULES, { probe_mark: '0x04000000' });
  assert.equal(c.ok, false); assert.ok(c.violations.some((v) => v.code === 'probe_mark_overlap'));
  ok('probe mark overlapping FakeIP: refused');
}
console.log(`autotune_contract: PASS (${checks} checks)`);
JS
