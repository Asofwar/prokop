"use strict";

// Configuration normalization (config/migration.uc) over generated configs
// (UC-156, safety invariant 16: migrations never lose user data):
//   - migrating a migrated config is a fixed point (nothing changes);
//   - the migrations are idempotent on their own: without the applied
//     markers a second run changes nothing but the markers (for configs
//     that had no markers, so that every migration ran the first time);
//   - options unknown to Prokop and existing secrets survive unchanged.
// Configs are random mixes of legacy (Podkop, older Prokop) and current
// sections with random option subsets and unknown options.
// Usage: config_migration.js <prokop lib> <work dir>

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { Rng, seedFrom, casesFrom, ucodeBatch, forAll, exercised } = require("./scaffold");

const [lib, work] = process.argv.slice(2);
const seed = seedFrom(1560004);
const rng = new Rng(seed);

const [defaults] = ucodeBatch(lib, `
let core = require("core.constants");
function evaluate(input) {
    return { legacy: core.ZAPRET_LEGACY_DEFAULT_NFQWS_OPT, current: core.ZAPRET_DEFAULT_NFQWS_OPT };
}
`, [{}]);
const env = { ...process.env, PROKOP_LIB: lib,
  ZAPRET_LEGACY_DEFAULT_NFQWS_OPT: defaults.legacy, ZAPRET_DEFAULT_NFQWS_OPT: defaults.current };

const SETTINGS = {
  download_lists_via_proxy: "1", download_subscriptions_via_proxy: "1", download_lists_via_proxy_section: "legacy-urltest",
  dns_server: "9.9.9.9", bootstrap_dns_server: "1.1.1.1", routing_excluded_ips: ["192.0.2.0/24"],
  enable_component_checks: "0", mirror_base_url: "https://mirror.example/", yacd_secret_key: "0123456789abcdef0123456789abcdef",
  config_version: "1.0.1",
};
const MARKERS = ["interface_sections", "enable_component_checks", "http_connection_urls", "flintnet_urltest_default",
  "retired_secondary_rulesets", "clash_api_secret_v1", "urltest_section_names_v1"];
const TEMPLATES = [
  ["rule", { ".name": "legacy-url", connection_type: "proxy", proxy_config_type: "url", enabled: "1",
    proxy_string: "vless://one\n//commented\n ss://two ", enable_udp_over_tcp: "1", urltest_check_interval_disabled: "1",
    domain: ["Example.COM", "full:Already.EXAMPLE"], domain_keyword_text_mode: "1", domain_keyword_text: "Video, Stream # comment",
    domain_regex_text: "^api[.]example$, ^cdn[.]example$", rule_set: ["https://example.com/domains.srs"],
    rule_set_with_subnets: ["https://example.com/mixed.srs"] }],
  ["section", { ".name": "legacy-sub", action: "proxy", proxy_config_type: "subscription", subscription_url: "https://example.com/sub.txt",
    subscription_user_agent: "Agent/1.0", subscription_update_interval_disabled: "1", urltest_enabled: "1",
    urltest_filter_mode: "include", detect_server_country: "1" }],
  ["section", { ".name": "legacy-urltest", connection_type: "proxy", proxy_config_type: "urltest",
    urltest_proxy_links: ["vmess://a", "vmess://a", "trojan://b"], urltest_exclude_regex: ["bad.*"], urltest_enabled: "1" }],
  ["section", { ".name": "legacy-list-sub", action: "proxy",
    subscription_urls: ["https://example.com/list.txt | ListAgent/2.0", "https://example.com/auto.txt"], subscription_update_interval: "6h" }],
  ["section", { ".name": "legacy-direct", action: "direct", ip_cidr: ["198.51.100.0/24"] }],
  ["section", { ".name": "legacy-exclusion", connection_type: "exclusion", ip_cidr: ["203.0.113.0/24"] }],
  ["section", { ".name": "legacy-zap", action: "zapret", nfqws_opt: defaults.legacy, cmd_opts: "--legacy-bye" }],
  ["section", { ".name": "legacy-vpn", connection_type: "vpn", proxy_config_type: "interface", interface: "awg0",
    domain_resolver_enabled: "1", domain_resolver_dns_type: "doh", domain_resolver_dns_server: "https://dns.example/dns-query" }],
  ["section", { ".name": "legacy-outbound", action: "outbound",
    outbound_json: '{"type":"socks","server":"127.0.0.1","server_port":1080,"version":"5"}',
    outbound_detour_enabled: "1", outbound_detour_section: "legacy-url" }],
  ["section", { ".name": "current-connection", action: "connection", connection_type: "url",
    proxy_links: ["http://user:pass@proxy.example:8080", "vless://id@host:443"], domain_suffix: ["example.org"] }],
  ["section", { ".name": "current-zapret", action: "zapret", nfqws_opt: defaults.current, domain_suffix: ["youtube.com"] }],
  ["section", { ".name": "current-block", action: "block", community_lists: ["russia_inside"], enabled: "0" }],
];

function unknownValue() {
  return rng.bool() ? `v${rng.int(0, 999)} with spaces` : rng.array(1, 3, () => `item-${rng.int(0, 99)}`);
}
function withUnknown(section) {
  for (let i = rng.int(0, 2); i > 0; i--) section[`x_prop_${rng.int(0, 9999)}`] = unknownValue();
  return section;
}
function fixture() {
  const settings = { ".name": "settings", ".type": "settings" };
  for (const [key, value] of Object.entries(SETTINGS)) if (rng.bool(0.4)) settings[key] = value;
  if (rng.bool(0.3)) settings.applied_migrations = rng.subset(MARKERS);
  withUnknown(settings);
  const config = { settings };
  for (const [type, template] of rng.subset(TEMPLATES, 0.4)) {
    const section = { ".name": template[".name"], ".type": type };
    for (const [key, value] of Object.entries(template)) if (key !== ".name" && rng.bool(0.8)) section[key] = value;
    (config[type] = config[type] || []).push(withUnknown(section));
  }
  return { source: rng.pickWeighted([[2, "prokop"], [1, "podkop"]]), config };
}

let runs = 0;
function migrate(config, source) {
  const file = path.join(work, `fixture-${runs++}.json`);
  fs.writeFileSync(file, JSON.stringify(config));
  return JSON.parse(execFileSync("ucode", ["-L", lib, path.join(lib, "config/migration.uc"), "migrate-fixture", file, source], { env }).toString());
}
const sections = (config) => Object.values(config).flatMap((v) => (Array.isArray(v) ? v : [v]));
const withoutMarkers = (config) => ({ ...config, settings: { ...config.settings, applied_migrations: undefined } });

const cases = Array.from({ length: casesFrom(60) }, fixture);
let changedCases = 0, unknownOptions = 0, secrets = 0, unmarkedCases = 0;
forAll("migration keeps unknown options and reaches a fixed point", seed, cases, ({ source, config }) => {
  const first = migrate(config, source);
  if (first.changed) changedCases++;
  const byName = new Map(sections(first.config).map((s) => [s[".name"], s]));
  for (const section of sections(config)) {
    const migrated = byName.get(section[".name"]);
    assert(migrated, `section ${section[".name"]} survives`);
    for (const [key, value] of Object.entries(section)) {
      if (!key.startsWith("x_prop_")) continue;
      unknownOptions++;
      assert.deepEqual(migrated[key], value, `${section[".name"]}.${key} is kept`);
    }
  }
  if (config.settings.yacd_secret_key) {
    secrets++;
    assert.equal(first.config.settings.yacd_secret_key, config.settings.yacd_secret_key, "an existing Clash API secret is kept");
  }

  const again = migrate(first.config, "prokop");
  assert.equal(again.changed, false, "a migrated config needs no further migration");
  assert.deepEqual(again.config, first.config);

  // Markers given in the input may skip a migration on purpose (the user
  // removed what it created); without input markers every migration ran.
  if (config.settings.applied_migrations !== undefined) return;
  unmarkedCases++;
  const unmarked = { ...first.config, settings: { ...first.config.settings } };
  delete unmarked.settings.applied_migrations;
  const rerun = migrate(unmarked, "prokop");
  assert.deepEqual(withoutMarkers(rerun.config), withoutMarkers(first.config), "migrations are idempotent without their markers");
  for (const op of rerun.operations) assert.equal(op.option, "applied_migrations", `a re-run only restores markers: ${JSON.stringify(op)}`);
});
exercised("configs the migration changed", changedCases, cases.length / 2);
exercised("unknown options", unknownOptions, cases.length);
exercised("existing secrets", secrets, cases.length / 10);
exercised("re-runs without markers", unmarkedCases, cases.length / 2);

console.log(`config migration properties passed (seed ${seed}: ${cases.length} configs, ${changedCases} changed, ` +
  `${unknownOptions} unknown options)`);
