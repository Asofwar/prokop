"use strict";

// routing/resolve.uc against an independent first-match model of sing-box
// and of nft's capture of real addresses (UC-096, UC-100, UC-103):
// generated rule lists shaped like the generator's (base rules, section
// rules on both tproxy inbounds, a rule's own resolve rule before its route
// rule, resolve rules of other rules, bypass and block rules) and targets
// of every kind the site check sends (FakeIP and real IPv4 with a host, an
// address literal, IPv6, FakeIP without its domain, the DNS port, UDP).
// A decided answer must be the model's; where the model cannot know (IPv6,
// DNS hijack, a FakeIP without its domain, an address after a foreign
// resolve, QUIC on UDP) the resolver must not decide.
// Usage: route_resolver_model.js <forkop lib> <forkop.uci fixture>

const assert = require("node:assert/strict");
const { Rng, seedFrom, casesFrom, ucodeBatch, forAll, exercised } = require("./scaffold");

const [lib, uciFixture] = process.argv.slice(2);
const seed = seedFrom(1000096);
const rng = new Rng(seed);
const CASES = casesFrom(600);

const T = ["tproxy-in", "tproxy6-in"];
const BASE = [
  { action: "sniff", inbound: ["tproxy-in", "tproxy6-in", "dns-in"] },
  { action: "hijack-dns", port: 53 },
  { action: "hijack-dns", protocol: "dns" },
  { action: "reject", inbound: T, protocol: "quic" },
];
const HOSTS = ["www.youtube.com", "youtube.com", "i.ytimg.com", "discord.com", "example.org", "a.example.org", "other.net"];
const SUFFIXES = ["youtube.com", "ytimg.com", "discord.com", "example.org", ".example.org", "org", "net"];
const KEYWORDS = ["tube", "disc", "exam", "Tube", "YouTube"];
const CIDRS = ["142.250.0.0/16", "93.184.216.0/24", "10.0.0.0/8", "93.184.216.34/32"];
const OUTBOUNDS = ["main-out", "youtube-out", "discord-out", "bypass-out"];
const REAL = ["142.250.1.1", "93.184.216.34", "1.1.1.1"];

function destination() {
  const rule = {};
  const kinds = rng.subset(["domain_suffix", "domain", "domain_keyword", "ip_cidr"], 0.4);
  if (!kinds.length) kinds.push(rng.pick(["domain_suffix", "ip_cidr", "none"]));
  for (const kind of kinds) {
    if (kind === "domain_suffix") rule.domain_suffix = rng.array(1, 2, () => rng.pick(SUFFIXES));
    if (kind === "domain") rule.domain = [rng.pick(HOSTS)];
    if (kind === "domain_keyword") rule.domain_keyword = [rng.pick(KEYWORDS)];
    if (kind === "ip_cidr") rule.ip_cidr = [rng.pick(CIDRS)];
  }
  return rule;
}
function filters(rule) {
  if (rng.bool(0.25)) rule.port = [rng.pick([443, 80, 8443])];
  if (rng.bool(0.1)) rule.port_range = [rng.pick(["400:500", "8000:9000"])];
  if (rng.bool(0.1)) rule.network = rng.pick(["tcp", "udp"]);
  return rule;
}
function routeRule() {
  const route = filters({ action: "route", inbound: T, ...destination() });
  if (!route.domain_suffix && !route.domain && !route.domain_keyword && !route.ip_cidr && !route.port && !route.port_range)
    route.port = [443];
  if (rng.bool(0.12)) route.action = "reject";
  else route.outbound = rng.pick(OUTBOUNDS);
  return route;
}
// A rule's own resolve rule: its matchers without ip_cidr and network.
function ownResolvePair() {
  const route = routeRule();
  if (!route.domain_suffix && !route.domain && !route.domain_keyword) route.domain_suffix = [rng.pick(SUFFIXES)];
  const resolve = { inbound: T, action: "resolve", server: "dns-server" };
  for (const key of ["domain", "domain_suffix", "domain_keyword", "port", "port_range"])
    if (route[key] !== undefined) resolve[key] = route[key];
  return [resolve, route];
}
function foreignResolve() {
  return { inbound: T, action: "resolve", server: "dns-server", domain_suffix: rng.array(1, 2, () => rng.pick(SUFFIXES)) };
}
function rules() {
  const list = [...BASE];
  const n = rng.int(0, 5);
  for (let i = 0; i < n; i++) {
    const kind = rng.pickWeighted([[6, "route"], [2, "pair"], [1, "foreign"]]);
    if (kind === "route") list.push(routeRule());
    else if (kind === "pair") list.push(...ownResolvePair());
    else list.push(foreignResolve());
  }
  return list;
}
function target() {
  const kind = rng.pickWeighted([[6, "fakeip"], [5, "real"], [1, "literal"], [1, "ipv6"], [1, "fakeip6"], [1, "nohost"]]);
  const host = rng.pick(HOSTS);
  const t = { kind, port: rng.pickWeighted([[8, 443], [1, 80], [1, 53], [1, 8443]]), network: rng.pickWeighted([[6, "tcp"], [1, "udp"]]) };
  if (kind === "fakeip") Object.assign(t, { host, ip: "198.18.0.7", fakeip: true });
  if (kind === "real") Object.assign(t, { host, ip: rng.pick(REAL), fakeip: false });
  if (kind === "literal") Object.assign(t, { host: "", ip: rng.pick(REAL), fakeip: false });
  if (kind === "ipv6") Object.assign(t, { host, ip: "2a00:1450:4001::1", fakeip: false });
  if (kind === "fakeip6") Object.assign(t, { host, ip: "fc00::7", fakeip: true });
  if (kind === "nohost") Object.assign(t, { host: "", ip: "198.18.0.9", fakeip: true });
  return t;
}

// ---- the model ----------------------------------------------------------------

const list = (v) => (v === undefined ? [] : Array.isArray(v) ? v : [v]);
function inCidr(ip, cidr) {
  const [base, len = "32"] = cidr.split("/");
  const n = (a) => a.split(".").reduce((acc, x) => acc * 256 + Number(x), 0);
  const size = 2 ** (32 - Number(len));
  return Math.floor(n(ip) / size) === Math.floor(n(base) / size);
}
function portOk(r, t) {
  if (r.port === undefined && r.port_range === undefined) return true;
  if (list(r.port).includes(t.port)) return true;
  return list(r.port_range).some((x) => {
    const [a, b] = x.split(":");
    return (a === "" || t.port >= Number(a)) && (b === "" || t.port <= Number(b));
  });
}
// sing-box: the host lower-cased, values as written; ip_cidr on the real
// destination ("unknown" once a resolve rule replaced it).
function hostHit(r, host) {
  if (!host) return false;
  const h = host.toLowerCase();
  if (list(r.domain).some((d) => d === h)) return true;
  if (list(r.domain_keyword).some((k) => h.includes(k))) return true;
  return list(r.domain_suffix).some((s) => {
    const sub = s.startsWith(".");
    const v = sub ? s.slice(1) : s;
    return (!sub && h === v) || h.endsWith("." + v);
  });
}
function matches(r, t, ip) {
  if (r.network !== undefined && !list(r.network).includes(t.network)) return "no";
  if (!portOk(r, t)) return "no";
  const dest = ["domain", "domain_suffix", "domain_keyword", "ip_cidr"].some((k) => r[k] !== undefined);
  if (!dest) return "match";
  if (hostHit(r, t.host)) return "match";
  if (r.ip_cidr === undefined) return "no";
  if (ip === "unknown") return "unknown";
  return ip !== null && list(r.ip_cidr).some((c) => inCidr(ip, c)) ? "match" : "no";
}
const takes = (r) => r.inbound === undefined || list(r.inbound).includes("tproxy-in");

function singbox(rulesList, t) {
  // A FakeIP connection carries the domain; its address is the domain's.
  let ip = t.fakeip ? null : t.ip;
  for (let i = 0; i < rulesList.length; i++) {
    const r = rulesList[i];
    if (!takes(r)) continue;
    const action = r.action || "route";
    if (action === "sniff") continue;
    if (action === "hijack-dns") {
      if (r.protocol !== undefined) continue; // the asked traffic is not DNS
      if (portOk(r, t)) return { unknown: "dns" };
      continue;
    }
    if (action === "reject" && r.protocol !== undefined) {
      if (t.network === "udp") return { unknown: "quic" };
      continue;
    }
    const m = matches(r, t, ip);
    if (action === "resolve") {
      // A real address is the answer the client got for the sniffed name:
      // the resolve gives it again. A FakeIP one gets an address the model
      // does not know.
      if (m !== "no" && t.fakeip) ip = "unknown";
      continue;
    }
    if (m === "no") continue;
    if (m === "unknown") return { unknown: "resolved_address" };
    return { rule: i, outbound: action === "reject" ? null : r.outbound, reject: action === "reject" };
  }
  return { rule: null, outbound: "direct-out" };
}
// nft: the first rule whose sets take the address (ip_cidr, or ports when
// the rule has no destination matcher); bypass leaves it direct.
function captured(rulesList, t) {
  for (const r of rulesList) {
    if (!takes(r) || !["route", "reject"].includes(r.action || "route") || r.protocol !== undefined) continue;
    const dest = ["domain", "domain_suffix", "domain_keyword", "ip_cidr"].some((k) => r[k] !== undefined);
    if (dest && r.ip_cidr === undefined) continue;
    if (matches({ ...r, domain: undefined, domain_suffix: undefined, domain_keyword: undefined }, { ...t, host: "" }, t.ip) !== "match")
      continue;
    return r.outbound !== "bypass-out";
  }
  return false;
}
function model(rulesList, t) {
  if (t.kind === "ipv6" || t.kind === "fakeip6") return { unknown: "ipv6" };
  if (t.kind === "nohost") return { unknown: "fakeip_domain" };
  const answer = singbox(rulesList, t);
  if (answer.unknown || t.fakeip) return answer;
  return captured(rulesList, t) ? answer : { direct: true };
}

const UCODE = `
let r = require("routing.resolve");
let sections = r.parse_config(__fs.readfile(getenv("ROUTE_FORKOP_UCI")));
const OUTBOUNDS = [
    { type: "direct", tag: "direct-out" }, { type: "direct", tag: "bypass-out" }, { type: "vless", tag: "main-out" },
    { type: "direct", tag: "youtube-out", routing_mark: 16777217 }, { type: "direct", tag: "discord-out", routing_mark: 16777218 }
];
function evaluate(input) {
    let config = { route: { final: "direct-out", rules: input.rules }, outbounds: OUTBOUNDS };
    let x = r.resolve(config, sections, r.target(input.t.host, input.t.ip,
        { fakeip: input.t.fakeip, port: input.t.port, network: input.t.network }));
    return { status: x.status, reason: x.reason, rule: x.route_rule, route: x.route, outbound: x.outbound };
}
`;

const cases = Array.from({ length: CASES }, () => ({ rules: rules(), t: target() }));
const results = ucodeBatch(lib, UCODE, cases, { ROUTE_FORKOP_UCI: uciFixture });
const models = cases.map((c) => model(c.rules, c.t));

forAll("a decided owner is the one sing-box and nft give; the unknowable is never decided", seed, cases, (c, i) => {
  const got = results[i], want = models[i];
  if (got.status !== "decided") return;
  assert.equal(want.unknown, undefined, `decided although the model cannot know (${want.unknown}): ${JSON.stringify(got)}`);
  if (want.direct) {
    // Not captured by nft: the connection never reaches sing-box.
    assert.ok(got.outbound === "direct-out" || got.outbound === "bypass-out", `not captured, so direct: ${JSON.stringify(got)}`);
    return;
  }
  assert.equal(got.rule, want.rule, `first-match rule: ${JSON.stringify(got)} vs ${JSON.stringify(want)}`);
  if (want.reject) assert.equal(got.route, "reject");
  else assert.equal(got.outbound, want.outbound, "outbound");
});

const decided = results.filter((r) => r.status === "decided").length;
exercised("decided answers", decided, CASES / 4);
exercised("decided FakeIP answers", cases.filter((c, i) => c.t.kind === "fakeip" && results[i].status === "decided").length, CASES / 8);
exercised("decided real-address answers", cases.filter((c, i) => c.t.kind === "real" && results[i].status === "decided").length, CASES / 20);
exercised("decided behind a rule's own resolve rule",
  cases.filter((c, i) => results[i].status === "decided" && results[i].rule > 0 && c.rules[results[i].rule - 1].action === "resolve").length, 5);
exercised("cases the model cannot know", models.filter((m) => m.unknown).length, CASES / 10);

console.log(`route resolver model passed (seed ${seed}: ${CASES} cases, ${decided} decided)`);
