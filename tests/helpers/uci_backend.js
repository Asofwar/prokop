"use strict";

// The backend side of the LuCI legacy rule option tests: a UCI state as the
// LuCI harness keeps it ({ sid: { ".name", ".type", ... } }) becomes a
// generator/validator fixture, and the real ucode modules report what they
// read from it.

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync, spawnSync } = require("node:child_process");

const ROOT = path.join(__dirname, "../..");
const LIB = path.join(ROOT, "prokop/files/usr/lib");

const SETTINGS = {
  ".name": "settings",
  ".type": "settings",
  log_level: "warn",
  dns_server: ["77.88.8.8"],
  bootstrap_dns_server: ["77.88.8.8"],
  yacd_secret_key: "test-clash-secret",
};

// Sections grouped by type, in UCI order, as the fixture cursors read them.
function fixtureFromUci(data) {
  const fixture = { settings: SETTINGS };
  for (const section of Object.values(data)) {
    const type = section[".type"];
    if (type === "settings") {
      fixture.settings = section;
      continue;
    }
    (fixture[type] ??= []).push(section);
  }
  return fixture;
}

const CONDITIONS_SCRIPT = `
let common = require("core.common");
let rule_config = require("config.rule");
let connections = require("config.connections");
let rule_conditions = require("routing.rule_conditions");
let data = json(require("fs").readfile(ARGV[0]));
connections.set_item_sections_from_data(data);
let out = {};
for (let s in (data.section || [])) {
    let ports = rule_config.rule_ports_csv_value(common.option(s, "ports", ""), common.option(s, "ports_text", ""));
    out[s[".name"]] = {
        domains: rule_conditions.domain_conditions(s),
        ip_cidr: rule_conditions.legacy_condition_values(s, "ip_cidr"),
        source_ip_cidr: rule_conditions.legacy_condition_values(s, "source_ip_cidr"),
        excluded_source_ip_cidr: rule_conditions.legacy_condition_values(s, "excluded_source_ip_cidr"),
        fully_routed_ips: common.list_option(s, "fully_routed_ips"),
        ports: ports == "" ? [] : split(ports, ","),
        interfaces: connections.interfaces(s)
    };
}
print(sprintf("%J\\n", out));
`;

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "prokop-legacy-"));
}

// What the generator and nft read as the conditions of every rule.
function effectiveConditions(data) {
  const work = tempDir();
  try {
    const fixture = path.join(work, "fixture.json");
    const script = path.join(work, "conditions.uc");
    fs.writeFileSync(fixture, JSON.stringify(fixtureFromUci(data)));
    fs.writeFileSync(script, CONDITIONS_SCRIPT);
    return JSON.parse(execFileSync("ucode", ["-L", LIB, script, fixture]).toString());
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

// The sing-box configuration generated from the UCI state, byte for byte
// (`text`), or the generator's refusal. `rulesets` pre-materializes list
// rule sets the list update would have written ({ file name: JSON }).
function generate(data, { rulesets = {}, singBoxVersion = "" } = {}) {
  const work = tempDir();
  try {
    const fixture = path.join(work, "fixture.json");
    const output = path.join(work, "config.json");
    fs.writeFileSync(fixture, JSON.stringify(fixtureFromUci(data)));
    fs.mkdirSync(`${output}.section-cache`);
    fs.mkdirSync(`${output}.rulesets`);
    for (const [name, content] of Object.entries(rulesets))
      fs.writeFileSync(path.join(`${output}.rulesets`, name), JSON.stringify(content));
    const args = [
      "-L", LIB, path.join(LIB, "singbox/generator.uc"),
      "generate-config-fixture", fixture, output, "127.0.0.1", "0", "", "", singBoxVersion,
    ];
    const result = spawnSync("ucode", args, {
      env: Object.assign({}, process.env, { TMP_SUBSCRIPTION_FOLDER: path.join(work, "subs") }),
    });
    if (result.status !== 0)
      return { ok: false, error: `${result.stderr}`.trim() || `exit ${result.status}` };
    // Paths inside the work directory differ per run.
    const text = fs.readFileSync(output, "utf8").split(work).join("<work>");
    return { ok: true, text, config: JSON.parse(text) };
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

// The validator verdict for the UCI state.
function validate(data) {
  const work = tempDir();
  try {
    const fixture = path.join(work, "fixture.json");
    fs.writeFileSync(fixture, JSON.stringify(fixtureFromUci(data)));
    const result = spawnSync(
      "ucode",
      ["-L", LIB, path.join(LIB, "config/validator.uc"), "validate-runtime-fixture", fixture, "{}"],
      { env: Object.assign({}, process.env, { PROKOP_LIB: LIB }) },
    );
    return { ok: result.status === 0, message: `${result.stdout}${result.stderr}`.trim() };
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

module.exports = { fixtureFromUci, effectiveConditions, generate, validate };
