"use strict";

// Scaffold for cheap seeded property tests (UC-156). No framework: node
// generates cases with a deterministic PRNG, the production ucode modules
// evaluate all of them in one process (ucodeBatch), node checks the
// properties (forAll). A fixed default seed keeps CI reproducible;
// PROPERTY_SEED and PROPERTY_CASES override the seed and the number of cases,
// and every failure prints the seed and the case to replay it.
//
//   const { Rng, seedFrom, casesFrom, ucodeBatch, forAll } = require("./scaffold");
//   const seed = seedFrom(20260929);
//   const rng = new Rng(seed);
//   const cases = Array.from({ length: casesFrom(300) }, () => ({ n: rng.int(0, 9) }));
//   const out = ucodeBatch(LIB, 'function evaluate(input) { return input.n * 2; }', cases);
//   forAll("doubles", seed, cases, (c, i) => assert.equal(out[i], c.n * 2));

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

// mulberry32: small, fast and good enough for test-case generation.
class Rng {
  constructor(seed) {
    this.state = seed >>> 0;
  }
  // Uniform float in [0, 1).
  next() {
    this.state = (this.state + 0x6d2b79f5) >>> 0;
    let t = this.state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }
  // Integer in [lo, hi], both inclusive.
  int(lo, hi) {
    return lo + Math.floor(this.next() * (hi - lo + 1));
  }
  bool(p = 0.5) {
    return this.next() < p;
  }
  pick(items) {
    assert(items.length > 0, "pick from an empty list");
    return items[this.int(0, items.length - 1)];
  }
  // pickWeighted([[weight, value], ...])
  pickWeighted(pairs) {
    const total = pairs.reduce((sum, [w]) => sum + w, 0);
    let x = this.next() * total;
    for (const [w, v] of pairs) {
      if (x < w) return v;
      x -= w;
    }
    return pairs[pairs.length - 1][1];
  }
  shuffle(items) {
    const out = [...items];
    for (let i = out.length - 1; i > 0; i--) {
      const j = this.int(0, i);
      [out[i], out[j]] = [out[j], out[i]];
    }
    return out;
  }
  // A random subset keeping the input order; each item with probability p.
  subset(items, p = 0.5) {
    return items.filter(() => this.bool(p));
  }
  array(min, max, make) {
    return Array.from({ length: this.int(min, max) }, (_, i) => make(i));
  }
  // Unsigned 32-bit integer.
  u32() {
    return (Math.floor(this.next() * 4294967296) >>> 0);
  }
}

function envInt(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  assert(/^[0-9]+$/.test(raw), `${name} must be a non-negative integer`);
  return Number(raw);
}

const seedFrom = (fallback) => envInt("PROPERTY_SEED", fallback);
const casesFrom = (fallback) => envInt("PROPERTY_CASES", fallback);

// Runs every input through `function evaluate(input)` of a ucode program in
// one ucode process with the Prokop library on the module path; returns the
// results in input order. `body` may require() production modules. Temporary
// files go to $PROPERTY_WORK (the calling test's work directory) or $TMPDIR.
function ucodeBatch(lib, body, inputs, env = {}) {
  const dir = fs.mkdtempSync(path.join(process.env.PROPERTY_WORK || os.tmpdir(), "prokop-property-"));
  try {
    const script = path.join(dir, "batch.uc");
    const input = path.join(dir, "input.json");
    fs.writeFileSync(script, `let __fs = require("fs");
${body}
let __out = [];
for (let __input in json(__fs.readfile(ARGV[0])))
    push(__out, evaluate(__input));
print(sprintf("%J\\n", __out));
`);
    fs.writeFileSync(input, JSON.stringify(inputs));
    const out = execFileSync("ucode", ["-L", lib, script, input], {
      env: { ...process.env, PROKOP_LIB: lib, ...env },
      maxBuffer: 256 * 1024 * 1024,
    });
    const results = JSON.parse(out.toString());
    assert.equal(results.length, inputs.length, "ucode evaluated every case");
    return results;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// Checks `check(item, index)` for every item; the first failure is reported
// with the seed and the offending case, then rethrown.
function forAll(name, seed, items, check) {
  items.forEach((item, index) => {
    try {
      check(item, index);
    } catch (error) {
      let shown = JSON.stringify(item);
      if (shown && shown.length > 4000) shown = shown.slice(0, 4000) + "...";
      console.error(`property "${name}" failed for case ${index} (replay: PROPERTY_SEED=${seed})`);
      console.error(`case: ${shown}`);
      throw error;
    }
  });
}

// A property that no generated case exercised proves nothing: requires at
// least `min` cases of a kind.
function exercised(name, count, min) {
  assert(count >= min, `property "${name}" was exercised by ${count} cases, want at least ${min}`);
}

module.exports = { Rng, seedFrom, casesFrom, ucodeBatch, forAll, exercised };
