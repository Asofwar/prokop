"use strict";

// The shared /proc/<pid>/stat parser of core/process_identity.uc (UC-158).
// The command name (field 2) is the only field that may contain spaces and
// parentheses: prctl and the executable name set it freely, up to 15 bytes.
// It therefore ends at the last ") " of the line, never the first. For
// synthetic lines with such names, stat_fields() must return the state,
// the parent pid and the start ticks the line encodes, and start_ticks()
// and parent_pid() must read the same fields.
// Usage: proc_stat.js <prokop lib>

const assert = require("node:assert/strict");
const { Rng, seedFrom, casesFrom, ucodeBatch, forAll, exercised } = require("./scaffold");

const [lib] = process.argv.slice(2);
const seed = seedFrom(1580001);
const rng = new Rng(seed);

const EDGE_NAMES = ["(a) b)", "x y", ") ", "(( ", "sing-box", "a) 1 2 3 4 5", ") Z ", "0123456789abcdef", ""];
const ALPHABET = ["a", "b", "z", "0", "9", " ", "(", ")", ")", " ", "-", "Z", "S", "R"];

function randomName() {
  return rng.array(0, 16, () => rng.pick(ALPHABET)).join("");
}

function statLine(c) {
  // Fields 3..52 of a stat line: state, ppid, then numbers with the start
  // ticks at field 22 (index 19 after the command name).
  const rest = [c.state, String(c.ppid)];
  for (let field = 5; field <= 52; field++) rest.push(field === 22 ? String(c.ticks) : String(rng.int(0, 99999)));
  return `${c.pid} (${c.name}) ${rest.join(" ")}\n`;
}

const cases = [];
for (const name of EDGE_NAMES) cases.push({ name });
while (cases.length < casesFrom(400)) cases.push({ name: randomName() });
for (const c of cases) {
  c.pid = rng.int(1, 4194304);
  c.ppid = rng.int(1, 4194304);
  c.ticks = rng.int(0, 2 ** 31);
  c.state = rng.pick(["R", "S", "D", "Z", "T", "I"]);
  c.text = statLine(c);
}

const out = ucodeBatch(lib, `
let identity = require("core.process_identity");
function evaluate(input) {
    return { fields: identity.stat_fields(input.text) };
}
`, cases);

forAll("stat_fields reads the fields after the last \") \"", seed, cases, (c, i) => {
  const fields = out[i].fields;
  assert(Array.isArray(fields), "a stat line has fields");
  assert.equal(fields[0], c.state, "state");
  assert.equal(fields[1], String(c.ppid), "parent pid");
  assert.equal(fields[19], String(c.ticks), "start ticks");
  assert.equal(fields.length, 50, "fields 3..52");
});
exercised("command names with \") \"", cases.filter((c) => c.name.includes(") ")).length, 20);
exercised("command names with spaces", cases.filter((c) => c.name.includes(" ")).length, 40);

// Lines without a command name are not parsed.
const [bad] = ucodeBatch(lib, `
let identity = require("core.process_identity");
function evaluate(input) {
    return map(input, (text) => identity.stat_fields(text));
}
`, [["", "123", "123 sleep S 1 2", null]]);
assert.deepEqual(bad, [null, null, null, null], "lines without a command name");

console.log(`proc stat parser properties passed (${cases.length} cases, seed ${seed})`);
