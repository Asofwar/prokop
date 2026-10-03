'use strict';

// Minimal nft evaluator for the autotune isolation regression tests.
//
// It follows one locally generated IPv4 packet through the temporary probe
// chains (the model printed by `autotune/isolation.uc model`) and then through
// the production output chains given as `nft -j` listings, and resolves the
// policy route that applies to it. Routing follows the kernel: a type-route
// output chain re-routes a packet with its new mark only when the chain ends
// in accept (nf_route_table_hook4 -> ip_route_me_harder); a queue verdict
// does not re-route (the saved mark equals the current one on reinjection).
// Only the parts of the nft JSON rule language used by Prokop output chains
// are implemented; anything else throws so a new construct cannot silently
// pass.

function ipToInt(ip) {
  const parts = String(ip).split('.').map(Number);
  if (parts.length !== 4 || parts.some((p) => !Number.isInteger(p) || p < 0 || p > 255)) return null;
  return ((parts[0] << 24) >>> 0) + (parts[1] << 16) + (parts[2] << 8) + parts[3];
}

function inPrefix(ip, addr, len) {
  const a = ipToInt(ip);
  const b = ipToInt(addr);
  if (a === null || b === null) return false;
  if (len === 0) return true;
  const mask = (0xffffffff << (32 - len)) >>> 0;
  return ((a & mask) >>> 0) === ((b & mask) >>> 0);
}

function elementMatches(value, element) {
  if (Array.isArray(value)) return Array.isArray(element) && element.length === value.length &&
    element.every((e, i) => elementMatches(value[i], e));
  if (typeof element === 'string' && element.includes('/')) {
    const [addr, len] = element.split('/');
    return typeof value === 'string' && inPrefix(value, addr, Number(len));
  }
  if (element && typeof element === 'object') {
    if (element.prefix) return typeof value === 'string' && inPrefix(value, element.prefix.addr, element.prefix.len);
    throw new Error(`unsupported set element ${JSON.stringify(element)}`);
  }
  if (typeof element === 'string' && element.includes('*')) throw new Error(`unsupported wildcard ${element}`);
  return value === element;
}

class Production {
  // listing: nftables array; sets: { name: [element, ...] } (missing sets are empty)
  constructor(listing, sets, table = 'ProkopTable') {
    this.table = table;
    this.sets = sets || {};
    this.chains = new Map();
    this.rules = new Map();
    const own = (o) => o && o.family === 'inet' && o.table === table;
    for (const item of listing) {
      if (item.chain && own(item.chain)) {
        this.chains.set(item.chain.name, item.chain);
        if (!this.rules.has(item.chain.name)) this.rules.set(item.chain.name, []);
      }
    }
    for (const item of listing) {
      if (item.rule && own(item.rule)) {
        if (!this.rules.has(item.rule.chain)) this.rules.set(item.rule.chain, []);
        this.rules.get(item.rule.chain).push(item.rule);
      }
    }
    for (const c of this.chains.values())
      if (['postrouting', 'egress'].includes(c.hook)) throw new Error(`simulator does not model ${c.hook} chain ${c.name}`);
  }

  baseOutputChains() {
    return [...this.chains.values()].filter((c) => c.hook === 'output').sort((a, b) => a.prio - b.prio);
  }

  value(left, pkt) {
    if (left.meta) {
      switch (left.meta.key) {
        case 'mark': return pkt.mark;
        case 'l4proto': return pkt.l4proto;
        case 'nfproto': return 'ipv4';
        case 'oifname': case 'oif': return pkt.oifname;
        default: throw new Error(`unsupported meta key ${left.meta.key}`);
      }
    }
    if (left.payload) {
      const { protocol, field } = left.payload;
      if (protocol === 'ip') return field === 'daddr' ? pkt.daddr : field === 'saddr' ? pkt.saddr : this.fail(left);
      if (protocol === 'ip6') return undefined;             // IPv4 packet: protocol mismatch
      if (protocol === pkt.l4proto) return field === 'dport' ? pkt.dport : field === 'sport' ? pkt.sport : this.fail(left);
      if (protocol === 'tcp' || protocol === 'udp') return undefined;
      return this.fail(left);
    }
    if (left['&']) {
      const [inner, mask] = left['&'];
      const v = this.value(inner, pkt);
      if (v === undefined) return undefined;
      if (typeof v !== 'number' || typeof mask !== 'number') throw new Error(`unsupported mask ${JSON.stringify(left)}`);
      return (v & mask) >>> 0;
    }
    if (left.concat) {
      const values = left.concat.map((l) => this.value(l, pkt));
      return values.some((v) => v === undefined) ? undefined : values;
    }
    return this.fail(left);
  }

  fail(what) { throw new Error(`unsupported expression ${JSON.stringify(what)}`); }

  contains(right, value) {
    if (typeof right === 'string' && right.startsWith('@')) {
      return (this.sets[right.slice(1)] || []).some((e) => elementMatches(value, e));
    }
    if (right && typeof right === 'object') {
      if (right.set) return right.set.some((e) => elementMatches(value, e));
      if (right.prefix) return elementMatches(value, right);
      throw new Error(`unsupported right-hand side ${JSON.stringify(right)}`);
    }
    return elementMatches(value, right);
  }

  match(m, pkt) {
    const value = this.value(m.left, pkt);
    if (value === undefined) return false;                  // protocol dependency fails for == and !=
    const hit = this.contains(m.right, value);
    if (m.op === '==' || m.op === 'in') return hit;
    if (m.op === '!=') return !hit;
    throw new Error(`unsupported op ${m.op}`);
  }

  // Runs a chain; returns { verdict: 'continue'|'return'|'accept'|'drop'|'queue', queue }.
  run(name, pkt, path, depth = 0) {
    if (depth > 16) throw new Error('jump depth exceeded');
    if (!this.chains.has(name)) throw new Error(`unknown chain ${name}`);
    const rules = this.rules.get(name) || [];
    for (let i = 0; i < rules.length; i++) {
      const rule = rules[i];
      for (const expr of rule.expr) {
        const [key] = Object.keys(expr);
        if (key === 'match') { if (!this.match(expr.match, pkt)) break; continue; }
        if (key === 'counter') continue;
        if (key === 'mangle') {
          const target = expr.mangle.key;
          if (!(target.meta && target.meta.key === 'mark') || typeof expr.mangle.value !== 'number')
            throw new Error(`unsupported mangle ${JSON.stringify(expr)}`);
          pkt.mark = expr.mangle.value >>> 0;
          path.push({ chain: name, position: i + 1, action: 'set_mark', mark: pkt.mark });
          continue;
        }
        if (key === 'return' || key === 'accept' || key === 'drop') {
          path.push({ chain: name, position: i + 1, action: key, rule });
          return { verdict: key };
        }
        if (key === 'queue') {
          path.push({ chain: name, position: i + 1, action: 'queue', queue: expr.queue.num, rule });
          return { verdict: 'queue', queue: expr.queue.num };
        }
        if (key === 'jump' || key === 'goto') {
          path.push({ chain: name, position: i + 1, action: key, target: expr[key].target });
          const r = this.run(expr[key].target, pkt, path, depth + 1);
          if (r.verdict === 'accept' || r.verdict === 'drop' || r.verdict === 'queue') return r;
          if (key === 'goto') return { verdict: 'return' };
          break;                                            // back from jump: next rule
        }
        throw new Error(`unsupported statement ${key}`);
      }
    }
    return { verdict: 'continue' };
  }

  // Base chain: end of chain / return apply the policy.
  runBase(chain, pkt, path) {
    const r = this.run(chain.name, pkt, path);
    if (r.verdict === 'continue' || r.verdict === 'return') {
      if (chain.policy === 'drop') return { verdict: 'drop' };
      return { verdict: 'accept' };
    }
    return r;
  }
}

function tupleMatches(rule, pkt) {
  if (!rule.tuple) return false;
  const t = rule.tuple;
  return pkt.daddr === t.daddr && pkt.l4proto === 'tcp' && pkt.dport === t.dport &&
    pkt.sport >= t.sport[0] && pkt.sport <= t.sport[1];
}

// One temporary chain from the isolation model.
function runProbeChain(chain, pkt, path) {
  for (const rule of chain.rules) {
    if (!tupleMatches(rule, pkt)) continue;
    if (rule.mark !== null && rule.mark !== pkt.mark) continue;
    if (rule.set_mark !== null) pkt.mark = rule.set_mark >>> 0;
    path.push({ chain: `ProkopAutotuneProbe/${chain.name}`, comment: rule.comment, action: rule.verdict, mark: pkt.mark });
    if (rule.verdict === null) continue;
    if (rule.verdict === 'queue') return { verdict: 'queue', queue: rule.queue };
    if (rule.verdict === 'drop') return { verdict: 'drop' };
    return { verdict: 'accept' };
  }
  return { verdict: 'accept' };                             // policy accept
}

function hexNumber(text) { return text === undefined ? undefined : parseInt(String(text), 16) >>> 0; }

// First policy rule that selects the packet's route lookup (fwmark with
// kernel semantics ((mark ^ value) & mask) == 0 and FIB_RULE_INVERT; other
// selectors are modelled for the probe: TCP, dport 443, sport, uid 0).
function routeTable(ipRules, mark, pkt = {}) {
  for (const rule of [...ipRules].sort((a, b) => a.priority - b.priority)) {
    if (rule.table === 'local') continue;
    let hit = true;
    if (rule.fwmark !== undefined) {
      const value = hexNumber(rule.fwmark);
      const mask = rule.fwmask === undefined ? 0xffffffff : hexNumber(rule.fwmask);
      if (((mark ^ value) & mask) >>> 0 !== 0) hit = false;
    }
    if (rule.ipproto !== undefined && rule.ipproto !== (pkt.l4proto || 'tcp')) hit = false;
    if (rule.dport !== undefined && Number(rule.dport) !== pkt.dport) hit = false;
    if (rule.dst !== undefined && rule.dst !== 'all' && !inPrefix(pkt.daddr, rule.dst, Number(rule.dstlen === undefined ? 32 : rule.dstlen))) hit = false;
    for (const key of Object.keys(rule))
      if (!['priority', 'src', 'table', 'fwmark', 'fwmask', 'not', 'ipproto', 'dport', 'dst', 'dstlen'].includes(key))
        throw new Error(`simulator does not model ip rule selector ${key}`);
    if ('not' in rule) hit = !hit;
    if (hit) return rule.table;
  }
  return null;
}

// Full output path of one packet: the temporary chains (priority -152/-151,
// before any production output chain), then every production output chain
// in priority order, then policy routing by the last re-routing mark.
function outputPath({ model, production, ipRules, pkt }) {
  const packet = { ...pkt };
  const path = [];
  let routeMark = pkt.mark;                                 // socket mark / SO_MARK of the injector
  const result = { initialMark: pkt.mark, probeQueue: null, productionQueue: null, dropped: null,
    finalMark: null, routeMark: null, route: null, path, productionTerminal: null, markAfterProbe: null };
  const chains = model.chains.filter((c) => c.hook === 'output').sort((a, b) => a.priority - b.priority);
  for (const chain of chains) {
    const entry = packet.mark;
    const r = runProbeChain(chain, packet, path);
    if (r.verdict === 'drop') { result.dropped = `probe:${chain.name}`; result.finalMark = packet.mark; return result; }
    if (r.verdict === 'queue') { result.probeQueue = r.queue; continue; }   // candidate accepts the original unchanged
    if (chain.type === 'route' && packet.mark !== entry) routeMark = packet.mark;
  }
  result.markAfterProbe = packet.mark;
  for (const chain of production.baseOutputChains()) {
    const entry = packet.mark;
    const before = path.length;
    const r = production.runBase(chain, packet, path);
    const terminal = path.slice(before).reverse().find((p) => p.rule);
    if (terminal) result.productionTerminal = { chain: chain.name, position: terminal.position, action: terminal.action, rule: terminal.rule };
    if (r.verdict === 'drop') { result.dropped = chain.name; break; }
    if (r.verdict === 'queue') { result.productionQueue = r.queue; break; }
    if (chain.type === 'route' && packet.mark !== entry) routeMark = packet.mark;
  }
  result.finalMark = packet.mark;
  result.routeMark = routeMark;
  result.route = routeTable(ipRules, routeMark, packet);
  return result;
}

module.exports = { Production, outputPath, routeTable, ipToInt };
