// Route/owner cases shared by the regression test. Each case: sing-box route
// rules, DNS answer (FakeIP or real) and target host.
const yt = { action: 'route', inbound: 'tproxy-in', domain_suffix: ['youtube.com'], outbound: 'youtube-out' };
const main = (extra) => ({ action: 'route', inbound: 'tproxy-in', outbound: 'main-out', ...extra });
module.exports = [
  ['zapret_owner', [yt]],
  ['first_match_connection', [main({ domain_suffix: ['youtube.com'] }), yt]],
  ['reject', [{ action: 'reject', inbound: 'tproxy-in', domain_suffix: ['youtube.com'] }, yt]],
  ['final', []],
  ['rule_set_before_owner', [main({ rule_set: ['remote-list'] }), yt]],
  ['rule_set_with_domain_hit', [main({ rule_set: ['remote-list'], domain_suffix: ['youtube.com'] }), yt]],
  ['domain_regex', [main({ domain_regex: ['.*tube.*'] }), yt]],
  ['logical', [{ type: 'logical', mode: 'and', rules: [], action: 'route', outbound: 'main-out' }, yt]],
  ['unknown_field', [main({ geosite: ['google'] }), yt]],
  ['source_scoped', [main({ domain_suffix: ['youtube.com'], source_ip_cidr: ['192.168.1.2/32'] }), yt]],
  ['fakeip_skips_ip_cidr', [main({ ip_cidr: ['142.250.0.0/16'] }), yt]],
  ['real_address_ip_cidr', [main({ ip_cidr: ['142.250.0.0/16'] }), yt], { dns: '142.250.1.1' }],
  // A resolve rule of another rule (other matchers) above the owner; a rule's
  // own resolve rule, directly before it with its matchers, does not count
  // (UC-103, tests/routing_resolve_edges.sh).
  ['resolve_above_owner_fakeip', [{ action: 'resolve', inbound: 'tproxy-in', domain_suffix: ['youtube.com', 'googlevideo.com'] }, yt]],
  ['resolve_above_owner_real', [{ action: 'resolve', inbound: 'tproxy-in', domain_suffix: ['youtube.com', 'googlevideo.com'] }, yt], { dns: '142.250.1.1' }],
  ['udp_only_rule', [main({ network: 'udp', domain_suffix: ['youtube.com'] }), yt]],
  ['port_80_rule', [main({ port: [80], domain_suffix: ['youtube.com'] }), yt]],
  ['port_range_rule', [main({ port_range: ['400:500'], domain_suffix: ['youtube.com'] }), yt]],
  ['quic_reject', [{ action: 'reject', inbound: 'tproxy-in', protocol: 'quic' }, yt]],
  ['tls_protocol', [main({ protocol: ['tls'] }), yt]],
  ['other_inbound', [{ inbound: ['dns-in'], action: 'hijack-dns' }, main({ inbound: ['mixed-in'], domain_suffix: ['youtube.com'] }), yt]],
  ['sniff_skipped', [{ action: 'sniff', inbound: 'tproxy-in' }, yt]],
  ['mark_mismatch', [yt], { mark: '0x01000009' }],
  ['second_zapret_rule', [{ ...yt, outbound: 'discord-out' }]],
  ['singbox_config_missing', null],
  ['suffix_subdomain_only_apex', [{ ...yt, domain_suffix: ['.youtube.com'] }], { host: 'youtube.com' }],
  ['suffix_subdomain_only_sub', [{ ...yt, domain_suffix: ['.youtube.com'] }]],
  ['keyword', [{ ...yt, domain_suffix: undefined, domain_keyword: ['tube'] }]],
  ['exact_domain_other_host', [{ ...yt, domain_suffix: undefined, domain: ['youtube.com'] }]],
  // The host is matched lower-cased; sing-box compares the rule's values as
  // written (the generator writes them in lower case, UC-099).
  ['case_insensitive', [{ ...yt, domain_suffix: ['youtube.com'] }], { host: 'WWW.YouTube.com' }],
];
