"use strict";

// Packet mark and NFQUEUE number layout (UC-156, safety invariants 5 and 12):
// the marks and queues come from the production modules, not from copies.
//   - FakeIP, outbound (the autotune probe mark), desync and post-NAT desync
//     marks of both providers are single bits and never share a bit with
//     another role;
//   - every Zapret and Zapret2 route mark (base + rule index) stays in its
//     provider's range, shares no bit with the role marks or the Tailscale
//     fwmark mask, and sing-box uses the same bases as nft;
//   - the DPI transition guard nft/apply.uc really installs drops every
//     route mark of its provider and none of the FakeIP, outbound, desync,
//     post-NAT or reinjected probe marks;
//   - production queue ranges do not overlap, and autotune isolation refuses
//     to run exactly when its queue range overlaps one of them.
// Usage: marks.js <prokop lib> <work dir>

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync, spawnSync } = require("node:child_process");
const { Rng, seedFrom, casesFrom, ucodeBatch, forAll, exercised } = require("./scaffold");

const [lib, work] = process.argv.slice(2);
const seed = seedFrom(1560003);
const rng = new Rng(seed);
const env = { ...process.env, PROKOP_LIB: lib };
const hex = (n) => "0x" + (n >>> 0).toString(16).padStart(8, "0");
const TAILSCALE_FWMARK_MASK = 0x00ff0000;

const [c] = ucodeBatch(lib, `
let core = require("core.constants");
let sb = require("singbox.constants");
function evaluate(input) {
    return { core, sb: { OUTBOUND_MARK: sb.OUTBOUND_MARK, ZAPRET_ROUTE_MARK_BASE: sb.ZAPRET_ROUTE_MARK_BASE,
        ZAPRET2_ROUTE_MARK_BASE: sb.ZAPRET2_ROUTE_MARK_BASE } };
}
`, [{}]);
const num = (name) => {
  const v = c.core[name];
  assert(v !== undefined && v !== null && v !== "", `core.constants ${name} is set`);
  return Number(v);
};
const role = {
  fakeip: num("NFT_FAKEIP_MARK"),
  outbound: num("NFT_OUTBOUND_MARK"),
  zapret_desync: num("ZAPRET_DESYNC_MARK"),
  zapret_postnat: num("ZAPRET_DESYNC_MARK_POSTNAT"),
  zapret2_desync: num("ZAPRET2_DESYNC_MARK"),
  zapret2_postnat: num("ZAPRET2_DESYNC_MARK_POSTNAT"),
};
const providers = {
  zapret: { base: num("ZAPRET_ROUTE_MARK_BASE"), size: num("ZAPRET_QUEUE_RANGE_SIZE"), queue: num("ZAPRET_QUEUE_BASE") },
  zapret2: { base: num("ZAPRET2_ROUTE_MARK_BASE"), size: num("ZAPRET2_QUEUE_RANGE_SIZE"), queue: num("ZAPRET2_QUEUE_BASE") },
};
const routeMarks = (p) => Array.from({ length: p.size }, (_, i) => (p.base + i + 1) >>> 0);

// Isolation model: the probe mark and what nfqws reinjects.
const model = JSON.parse(execFileSync("ucode", ["-L", lib, path.join(lib, "autotune/isolation.uc"), "model", "142.250.1.1"], { env }).toString());
const reinjected = model.chains.flatMap((chain) => chain.rules).filter((r) => r.comment === "reinjected").map((r) => r.mark);
assert.equal(reinjected.length, 1, "the isolation model has one reinjected-packet rule");

// The DPI transition guard batch, captured from a stub nft.
fs.mkdirSync(path.join(work, "bin"), { recursive: true });
const capture = path.join(work, "guard.nft");
fs.writeFileSync(path.join(work, "bin", "nft"), `#!/bin/sh
case "$1" in
  list) exit 1 ;;
  -f) cp "$2" "${capture}" ;;
esac
exit 0
`, { mode: 0o755 });
execFileSync("ucode", ["-L", lib, path.join(lib, "nft/apply.uc"), "install-dpi-transition-guard", "ProkopTable"],
  { env: { ...env, PATH: `${path.join(work, "bin")}:${process.env.PATH}` } });
const guardRules = [...fs.readFileSync(capture, "utf8").matchAll(/meta mark & (0x[0-9a-f]+) == (0x[0-9a-f]+) drop/g)]
  .map((m) => ({ mask: Number(m[1]), value: Number(m[2]) }));
assert.equal(guardRules.length, 2, "the guard drops two provider mark classes");
const dropped = (mark) => guardRules.filter((r) => ((mark & r.mask) >>> 0) === r.value);

// --- Role marks -------------------------------------------------------------------
const single = (n) => n > 0 && (n & (n - 1)) === 0;
forAll("role marks are single bits", seed, Object.entries(role), ([name, mark]) => {
  assert(single(mark), `${name} ${hex(mark)} is one bit`);
});
const distinctRoles = [["fakeip", role.fakeip], ["outbound", role.outbound], ["desync", role.zapret_desync], ["postnat", role.zapret_postnat]];
const rolePairs = [];
for (let i = 0; i < distinctRoles.length; i++)
  for (let j = i + 1; j < distinctRoles.length; j++) rolePairs.push([distinctRoles[i], distinctRoles[j]]);
for (const [name, mark] of [["zapret2 desync", role.zapret2_desync], ["zapret2 postnat", role.zapret2_postnat]])
  for (const other of distinctRoles.filter(([n]) => n === "fakeip" || n === "outbound")) rolePairs.push([[name, mark], other]);
rolePairs.push([["zapret2 desync", role.zapret2_desync], ["zapret2 postnat", role.zapret2_postnat]]);
forAll("role marks share no bit", seed, rolePairs, ([[a, ma], [b, mb]]) => {
  assert.equal((ma & mb) >>> 0, 0, `${a} ${hex(ma)} and ${b} ${hex(mb)}`);
});
assert.equal(model.probe_mark, role.outbound, "autotune probes with the outbound mark");
assert.equal(model.desync_mark, role.zapret_desync, "isolated nfqws uses the Zapret desync mark");

// --- Route mark ranges ------------------------------------------------------------
assert.equal(c.sb.ZAPRET_ROUTE_MARK_BASE, providers.zapret.base, "sing-box and nft use the same Zapret route mark base");
assert.equal(c.sb.ZAPRET2_ROUTE_MARK_BASE, providers.zapret2.base, "sing-box and nft use the same Zapret2 route mark base");
assert.equal(c.sb.OUTBOUND_MARK, role.outbound, "sing-box and nft use the same outbound mark");
const zapretMarks = routeMarks(providers.zapret);
const zapret2Marks = routeMarks(providers.zapret2);
const zapret2Set = new Set(zapret2Marks);
const roleBits = Object.values(role).reduce((a, b) => (a | b) >>> 0, TAILSCALE_FWMARK_MASK);
const allRouteMarks = [...zapretMarks.map((m) => ["zapret", m]), ...zapret2Marks.map((m) => ["zapret2", m])];
forAll("route marks stay clear of role bits and of each other", seed, allRouteMarks, ([provider, mark]) => {
  assert.equal((mark & roleBits) >>> 0, 0, `${provider} ${hex(mark)} shares a bit with a role mark or Tailscale`);
  const p = providers[provider];
  assert.equal((mark & 0xff000000) >>> 0, p.base, `${provider} ${hex(mark)} leaves its provider's range`);
  if (provider === "zapret") assert(!zapret2Set.has(mark), `${hex(mark)} is both a Zapret and a Zapret2 mark`);
});

// --- DPI transition guard ---------------------------------------------------------
forAll("the guard drops every provider route mark", seed, allRouteMarks, ([provider, mark]) => {
  const rules = dropped(mark);
  assert.equal(rules.length, 1, `${provider} ${hex(mark)} matches one guard rule`);
  assert.equal(rules[0].value, providers[provider].base, `${provider} ${hex(mark)} is dropped as ${provider}`);
});
const neverDropped = [...Object.entries(role), ["probe", model.probe_mark], ["reinjected probe", reinjected[0]],
  ["fakeip|outbound", role.fakeip | role.outbound]];
forAll("the guard never drops FakeIP, outbound, desync or probe traffic", seed, neverDropped, ([name, mark]) => {
  assert.equal(dropped(mark).length, 0, `${name} ${hex(mark)}`);
});
// Desync-marked packets of a provider (nfqws adds its desync bit to what it
// reinjects) are not the provider's routed traffic either.
const desyncCombos = Array.from({ length: casesFrom(200) }, () => {
  const [provider, mark] = rng.pick(allRouteMarks);
  return { provider, mark: (mark | rng.pick([role.zapret_desync, role.zapret_postnat])) >>> 0 };
});
forAll("the guard class is the whole top byte", seed, desyncCombos, ({ provider, mark }) => {
  assert.equal(dropped(mark).length, 0, `${provider} ${hex(mark)} with a desync bit`);
});

// --- Queue ranges -----------------------------------------------------------------
const range = (p) => [p.queue, p.queue + p.size - 1];
const overlaps = ([a0, a1], [b0, b1]) => a0 <= b1 && b0 <= a1;
assert(!overlaps(range(providers.zapret), range(providers.zapret2)), "Zapret and Zapret2 queue ranges overlap");
function isolation(queue) {
  const r = spawnSync("ucode", ["-L", lib, path.join(lib, "autotune/isolation.uc"), "none"], {
    env: { ...env, PROKOP_AUTOTUNE_QUEUE: String(queue), PROKOP_AUTOTUNE_STATE_DIR: path.join(work, "autotune") },
    encoding: "utf8",
  });
  if (r.stdout.trim() === "") return { refused: false };
  const out = JSON.parse(r.stdout);
  assert.equal(out.reason, "queue_overlaps_prokop_range");
  return { refused: true, last: out.queue_last };
}
const width = isolation(providers.zapret.queue).last - providers.zapret.queue + 1;
assert(width >= 1, "isolation reports its queue range");
assert.equal(isolation(model.queue).refused, false, `the default isolation queue ${model.queue} is usable`);
assert(!overlaps([model.queue, model.queue + width - 1], range(providers.zapret)) &&
  !overlaps([model.queue, model.queue + width - 1], range(providers.zapret2)), "the default isolation queues are free");
const edges = [range(providers.zapret), range(providers.zapret2)].flatMap(([a, b]) => [a - width, a - width + 1, a, b, b + 1]);
const queues = [...edges, ...Array.from({ length: casesFrom(40) }, () => rng.int(3900, 4700))];
let refusals = 0;
forAll("isolation refuses exactly the queues that overlap production", seed, queues, (q) => {
  const mine = [q, q + width - 1];
  const expected = overlaps(mine, range(providers.zapret)) || overlaps(mine, range(providers.zapret2));
  const got = isolation(q).refused;
  if (got) refusals++;
  assert.equal(got, expected, `queue ${q}..${q + width - 1}`);
});
exercised("refused isolation queues", refusals, 5);
exercised("accepted isolation queues", queues.length - refusals, 5);

console.log(`mark and queue properties passed (seed ${seed}: ${allRouteMarks.length} route marks, ` +
  `${desyncCombos.length} desync combinations, ${queues.length} isolation queues)`);
