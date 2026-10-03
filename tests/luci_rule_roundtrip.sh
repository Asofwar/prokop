#!/usr/bin/env bash
set -euo pipefail

# Round trip of the rule editor: the real LuCI section.js is loaded under node
# with a model of luci-base form.js (tests/helpers/luci_form_harness.js, 24.10
# and 25.12 parse semantics), on the Rules page as page/rules.js and
# configform.js build it. Opening a rule modal from that page and saving it
# without touching anything, or saving the page itself, must leave the rule's
# UCI section byte-for-byte unchanged.
# Also covers the rule-set item settings modal ("Include IP addresses and
# subnets"), which must not drop Built-in rule sets #2 (UC-003, UC-004).
# A select whose saved value is no longer offered (DPI provider not installed,
# referenced section disabled or gone) keeps that value, labels it, and
# refuses to save until the user picks another one (UC-008). Built-in rule
# sets #2 are hidden for DNS rules; values a DNS rule already has stay visible
# and the rule is refused until they are removed, never dropped or kept
# silently (UC-046). A refused save leaves UCI untouched. Legacy rule forms
# stay as they are until the user converts them (UC-042, UC-043, D-6 a).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment } = require(process.argv[2]);

// Built-in rule sets #2 are saved with their direct URL (the mirror is opt-in);
// URLs on the former upstream mirror are still read from older configs.
const B4 = 'https://raw.githubusercontent.com/Greeg0ry/b4geoip-forkop/main/srs';
const LEGACY_B4 = 'https://mirror.infotechtg.ru/forkop/lists/b4geoip-forkop/srs';
const VALVE = `${B4}/valve.srs`;
const GOOGLE = `${B4}/google.srs`;
const CUSTOM = 'https://example.com/custom.srs';
const CUSTOM_SUBNETS = 'https://example.com/with-subnets.srs';

// A Connection rule has a connection: the rule modal refuses to save one
// without (UC-092).
const CONNECTION_SOURCES = ['selector_proxy_links', 'subscription_urls', 'interfaces', 'interface',
  'outbound_json', 'outbound_jsons'];
function rule(values) {
  const connection = values.action === 'connection' && !CONNECTION_SOURCES.some((key) => key in values)
    ? { selector_proxy_links: ['socks5://10.0.0.1:1080'] } : {};
  return Object.assign({ '.name': 'rule', '.type': 'section', '.anonymous': false, enabled: '1' },
    connection, values);
}
// Connection-like actions always store the Mixed Proxy flag (form.Flag, rmempty=false).
const routed = { mixed_proxy_enabled: '0' };

const fixtures = {
  // UC-003: the only destination condition is a Built-in rule set #2.
  device_filter_secondary_only: rule({ action: 'connection', ...routed,
    rule_set_with_subnets: [VALVE], source_ip_cidr: ['192.168.1.50'] }),
  device_filter_secondary_only_block: rule({ action: 'block',
    rule_set_with_subnets: [GOOGLE], source_ip_cidr: ['192.168.1.51', '192.168.1.52'] }),
  // UC-003: legacy remote lists have no LuCI widget but the backend honours them.
  device_filter_remote_domain_lists: rule({ action: 'block',
    remote_domain_lists: ['https://example.com/domains.lst'], source_ip_cidr: ['192.168.1.50'] }),
  device_filter_remote_subnet_lists: rule({ action: 'connection', ...routed,
    remote_subnet_lists: ['https://example.com/subnets.lst'], source_ip_cidr: ['192.168.1.0/28'] }),
  // UC-004 storage: user subnet rule sets and Built-in #2 share one option.
  mixed_subnet_rule_sets: rule({ action: 'connection', ...routed, rule_set: [CUSTOM],
    rule_set_with_subnets: [CUSTOM_SUBNETS, VALVE], source_ip_cidr: ['192.168.1.50'] }),
  // Normal rules.
  community_device_filter: rule({ action: 'connection', ...routed,
    community_lists: ['youtube'], source_ip_cidr: ['192.168.1.50'] }),
  domains_and_links: rule({ action: 'connection', ...routed, label: 'Work',
    domain: 'example.com\nfull:exact.example.org', selector_proxy_links: ['socks5://10.0.0.1:1080'],
    community_lists: ['youtube', 'geoblock'], excluded_source_ip_cidr: ['192.168.1.9'] }),
  bypass_ip_ports: rule({ action: 'bypass', ip_cidr: '10.10.0.0/16', ports: ['443', '8000-8080'],
    fully_routed_ips: ['192.168.1.77'] }),
  block_domain_ip_lists: rule({ action: 'block', domain_ip_lists: ['https://example.com/list.lst'],
    source_ip_cidr: ['192.168.1.60'] }),
  dns_rule: rule({ action: 'dns', dns_type: 'udp', dns_server: '1.1.1.1', dns_detour_enabled: '0',
    domain: 'example.net', community_lists: ['youtube'], source_ip_cidr: ['192.168.1.50'] }),
  disabled_rule: rule({ enabled: '0', action: 'connection', ...routed, community_lists: ['youtube'],
    outbound_detour_enabled: '1', outbound_detour_section: 'transit', sort_by_latency: '1' }),
  // UC-008 control: DPI rules round-trip while their provider is installed.
  zapret_rule: rule({ action: 'zapret', ...routed, nfqws_opt: '--filter-tcp=443 --dpi-desync=fake',
    community_lists: ['youtube'] }),
  zapret2_rule: rule({ action: 'zapret2', ...routed, nfqws2_opt: '--filter-tcp=443 --lua-desync=fake:blob=fake_default_tls',
    community_lists: ['youtube'] }),
  byedpi_rule: rule({ action: 'byedpi', ...routed, byedpi_cmd_opts: '-o 1 -d 1', community_lists: ['youtube'] }),
  // D-6 (a): legacy forms stay until the user converts them explicitly
  // (tests/luci_legacy_rule_conversion.sh checks the conversion).
  legacy_domain_forms: rule({ action: 'block', domain: ['exact.example'], domain_keyword: ['video'],
    domain_regex_text: '^cdn', domain_suffix_text: 'other.example' }),
  legacy_text_mode: rule({ action: 'bypass', ip_cidr: ['1.1.1.1'], ip_cidr_text: '8.8.8.8',
    source_ip_cidr_text: '192.168.1.3', conditions_text_mode: '1', ports_text: '53' }),
  legacy_interfaces: rule({ action: 'connection', ...routed, domain: 'example.com', interfaces: ['awg0'],
    interface_settings: '{"awg0":{"domain_resolver_enabled":"1"}}' }),
  legacy_unsupported: rule({ action: 'block', domain: 'example.com', local_domain_lists: ['/etc/list.lst'],
    fully_routed_ips_text: '192.168.1.7' }),
  // DNS rules do not use destination IPs and ports; the fields are hidden
  // and what the rule stores stays until it is removed there.
  legacy_dns_ip_list_ports: rule({ action: 'dns', dns_type: 'udp', dns_server: '1.1.1.1', dns_detour_enabled: '0',
    domain: 'example.net', ip_cidr: ['1.1.1.1'], ports: ['443', '8000-8080'] }),
  legacy_dns_ip_option: rule({ action: 'dns', dns_type: 'udp', dns_server: '1.1.1.1', dns_detour_enabled: '0',
    domain: 'example.net', ip_cidr: '10.0.0.0/8' }),
  // D-23: the kill-switch with the DNS exemption of its excluded devices,
  // and the exemption kept while the kill-switch is off.
  killswitch_dns_exempt: rule({ action: 'connection', ...routed, domain: 'example.com', kill_switch: '1',
    kill_switch_dns_exempt: '1', excluded_source_ip_cidr: ['192.168.1.9'] }),
  killswitch_dns_exempt_kept: rule({ action: 'connection', ...routed, domain: 'example.com',
    kill_switch_dns_exempt: '1', excluded_source_ip_cidr: ['192.168.1.9'] }),
  // Both flags as the CLI may spell them (core/common.uc bool_option).
  killswitch_spelled_yes: rule({ action: 'connection', ...routed, domain: 'example.com', kill_switch: 'yes',
    kill_switch_dns_exempt: 'on', excluded_source_ip_cidr: ['192.168.1.9'] }),
  killswitch_spelled_no: rule({ action: 'connection', ...routed, domain: 'example.com', kill_switch: 'true',
    kill_switch_dns_exempt: 'no', excluded_source_ip_cidr: ['192.168.1.9'] }),
};

// UC-046: DNS rules with Built-in rule sets #2 (only the CLI or an older
// editor could store them). validator.uc rejects any rule_set_with_subnets
// entry on a DNS rule.
const dnsWithSecondary = {
  dns_rule_secondary_rule_sets: rule({ action: 'dns', dns_type: 'udp', dns_server: '1.1.1.1',
    dns_detour_enabled: '0', domain: 'example.net', rule_set_with_subnets: [VALVE] }),
  dns_rule_sets_and_secondary: rule({ action: 'dns', dns_type: 'udp', dns_server: '1.1.1.1',
    dns_detour_enabled: '0', rule_set: [CUSTOM], rule_set_with_subnets: [GOOGLE] }),
};
const SECONDARY_ON_DNS = /Built-in rule sets #2 are not supported for DNS rules/;

// Rules that reference other sections, for UC-008.
function target(values) {
  return Object.assign({ '.type': 'section', '.anonymous': false, enabled: '1' }, values);
}
const targets = {
  vpn: target({ '.name': 'vpn', label: 'VPN', action: 'connection', ...routed,
    selector_proxy_links: ['socks5://10.0.0.1:1080'] }),
  off: target({ '.name': 'off', label: 'Old VPN', enabled: '0', action: 'connection', ...routed,
    selector_proxy_links: ['socks5://10.0.0.2:1080'] }),
  dpi: target({ '.name': 'dpi', label: 'Zapret', action: 'zapret', community_lists: ['youtube'] }),
};
const dnsThrough = (section) => rule({ action: 'dns', dns_type: 'udp', dns_server: '1.1.1.1',
  domain: 'example.net', dns_detour_enabled: '1', dns_detour_section: section });

// Every case runs; all failures are reported together.
const failures = [];
async function check(label, fn) {
  try {
    await fn();
  } catch (error) {
    failures.push(`${label}: ${error.message}`);
  }
}

(async () => {
  for (const version of ['24.10', '25.12']) {
    for (const [name, fixture] of Object.entries(fixtures))
      await check(`${version} ${name}`, async () => {
        const env = createEnvironment({ version, config: { rule: fixture } });
        await (await env.openRule('rule')).save();
        assert.deepEqual(env.uci.data.rule, fixture, 'an unchanged rule modal save changed UCI');
      });

    // Save & Apply of the Rules page saves its map first: the rules grid
    // parses the Enable checkbox of every row.
    for (const [name, fixture] of Object.entries(fixtures))
      await check(`${version} ${name}: Rules page`, async () => {
        const env = createEnvironment({ version, config: { rule: fixture } });
        await (await env.openRules()).save();
        assert.deepEqual(env.uci.data.rule, fixture, 'an unchanged Rules page save changed UCI');
      });

    // A Built-in rule set #2 picked in the editor is saved with its direct URL,
    // and one stored on the former upstream mirror is read as the same choice.
    await check(`${version} Built-in rule sets #2 use direct URLs`, async () => {
      const env = createEnvironment({ version, config: { rule: rule({ action: 'connection', ...routed,
        rule_set_with_subnets: [`${LEGACY_B4}/valve.srs`, CUSTOM_SUBNETS] }) } });
      const modal = await env.openRule('rule');
      const field = modal.option('secondary_rule_sets').getUIElement('rule');
      assert.deepEqual(field.getValue(), ['valve'], 'a former mirror URL must be read as a built-in choice');
      field.setValue(['valve', 'google']);
      await modal.save();
      assert.deepEqual(env.uci.data.rule.rule_set_with_subnets, [CUSTOM_SUBNETS, VALVE, GOOGLE]);
      assert(!JSON.stringify(env.uci.data.rule).includes('mirror.'), 'no mirror URL may be written');
    });

    // UC-008: a DPI rule whose provider is not installed keeps its action and
    // strategy; Save is refused until another action is chosen explicitly.
    for (const [action, strategy] of [['zapret', 'nfqws_opt'], ['zapret2', 'nfqws2_opt'],
      ['byedpi', 'byedpi_cmd_opts']])
      await check(`${version} ${action} without provider`, async () => {
        const fixture = fixtures[`${action}_rule`];
        const env = createEnvironment({ version, config: { rule: fixture },
          providers: { zapretInstalled: false, zapret2Installed: false, byedpiInstalled: false } });
        const modal = await env.openRule('rule');
        const option = modal.option('action');
        assert.equal(option.formvalue('rule'), action, 'the widget must keep the saved action');
        assert.match(option.vallist[option.keylist.indexOf(action)], /\(not installed\)$/);
        assert.equal(modal.active(strategy), true, 'the strategy stays visible');
        await assert.rejects(modal.save(), /not installed/);
        assert.deepEqual(env.uci.data.rule, fixture, 'a refused save changed UCI');

        // An explicit choice is saved; switching away clears the strategy.
        option.getUIElement('rule').setValue('bypass');
        await modal.save();
        assert.equal(env.uci.data.rule.action, 'bypass');
        assert.equal(env.uci.data.rule[strategy], undefined);

        // A new rule is still offered only installed providers.
        const fresh = createEnvironment({ version, config: { rule: rule({ action: 'block',
          community_lists: ['youtube'] }) }, providers: { zapretInstalled: false,
          zapret2Installed: false, byedpiInstalled: false } });
        assert.equal((await fresh.openRule('rule')).option('action').keylist.includes(action), false);
      });

    // UC-008: DNS through a disabled, uninstalled or deleted section.
    for (const [label, section, providers, mark] of [
      ['disabled section', 'off', undefined, /^Old VPN \(disabled\)$/],
      ['provider not installed', 'dpi', { zapretInstalled: false }, /^Zapret \(provider not installed\)$/],
      ['deleted section', 'gone', undefined, /^gone \(unavailable\)$/],
    ]) await check(`${version} dns through ${label}`, async () => {
      const config = { rule: dnsThrough(section), ...targets };
      const env = createEnvironment({ version, config, providers });
      const modal = await env.openRule('rule');
      const option = modal.option('dns_detour_section');
      assert.equal(option.formvalue('rule'), section, 'the widget must keep the saved section');
      assert.match(option.vallist[option.keylist.indexOf(section)], mark);
      assert.equal(option.keylist.includes('vpn'), true);
      await assert.rejects(modal.save());
      assert.deepEqual(env.uci.data, config, 'a refused save changed UCI');

      option.getUIElement('rule').setValue('vpn');
      await modal.save();
      assert.equal(env.uci.data.rule.dns_detour_section, 'vpn');
    });

    // UC-008 control: DNS through a DPI section whose provider is installed
    // round-trips on the first open of the editor, before anything else has
    // asked for provider availability.
    await check(`${version} dns through installed DPI section`, async () => {
      const config = { rule: dnsThrough('dpi'), ...targets };
      const env = createEnvironment({ version, config });
      const modal = await env.openRule('rule');
      const option = modal.option('dns_detour_section');
      assert.equal(option.formvalue('rule'), 'dpi');
      assert.equal(option.vallist[option.keylist.indexOf('dpi')], 'Zapret');
      await modal.save();
      assert.deepEqual(env.uci.data, config, 'an unchanged rule modal save changed UCI');
    });

    // UC-008: a subscription downloaded through a disabled section.
    await check(`${version} subscription download through disabled section`, async () => {
      const config = {
        rule: rule({ action: 'connection', ...routed, community_lists: ['youtube'],
          subscription_url: ['sub'] }),
        sub: { '.name': 'sub', '.type': 'subscription_url', '.anonymous': false, section: 'rule',
          url: 'https://example.com/sub', subscription_update_enabled: '1',
          subscription_update_interval: '4h', download_via_proxy_enabled: '1',
          download_via_proxy_section: 'off' },
        ...targets,
      };
      const env = createEnvironment({ version, config });
      const modal = await env.openRule('rule');
      const settings = await modal.openItemSettings('subscription_url', 'sub');
      const option = settings.map.children[0].children.find((o) => o.option === 'download_via_proxy_section');
      assert.equal(option.formvalue('settings'), 'off', 'the widget must keep the saved section');
      assert.match(option.vallist[option.keylist.indexOf('off')], /^Old VPN \(disabled\)$/);
      await settings.save();
      assert.deepEqual(env.uci.data, config, 'a refused subscription settings save changed UCI');
      await assert.rejects(settings.map.parse(), /disabled/);

      // Control: an installed DPI section stays a plain choice.
      const dpiConfig = { ...config, sub: { ...config.sub, download_via_proxy_section: 'dpi' } };
      const dpiEnv = createEnvironment({ version, config: dpiConfig });
      const dpiSettings = await (await dpiEnv.openRule('rule')).openItemSettings('subscription_url', 'sub');
      const dpiOption = dpiSettings.map.children[0].children.find((o) => o.option === 'download_via_proxy_section');
      assert.equal(dpiOption.vallist[dpiOption.keylist.indexOf('dpi')], 'Zapret');
      await dpiSettings.map.parse();
      await dpiSettings.save();
      assert.deepEqual(dpiEnv.uci.data, dpiConfig, 'an unchanged subscription settings save changed UCI');
    });

    // UC-046: a DNS rule does not show Built-in rule sets #2; routing rules do.
    await check(`${version} dns rule hides Built-in rule sets #2`, async () => {
      const env = createEnvironment({ version, config: { rule: fixtures.dns_rule } });
      assert.equal((await env.openRule('rule')).active('secondary_rule_sets'), false);

      const routedRule = createEnvironment({ version, config: { rule: fixtures.device_filter_secondary_only } });
      assert.equal((await routedRule.openRule('rule')).active('secondary_rule_sets'), true);
    });

    // UC-046: values a DNS rule already has stay visible, and Save is refused
    // until the user removes them; the other rule sets are kept.
    for (const [name, fixture] of Object.entries(dnsWithSecondary))
      await check(`${version} ${name}`, async () => {
        const env = createEnvironment({ version, config: { rule: fixture } });
        const modal = await env.openRule('rule');
        assert.equal(modal.active('secondary_rule_sets'), true, 'stored values must stay visible');
        await assert.rejects(modal.save(), SECONDARY_ON_DNS);
        assert.deepEqual(env.uci.data.rule, fixture, 'a refused save changed UCI');

        modal.option('secondary_rule_sets').getUIElement('rule').setValue([]);
        await modal.save();
        const { rule_set_with_subnets, ...expected } = fixture;
        assert.deepEqual(env.uci.data.rule, expected);
      });

    // UC-046: a routing rule with Built-in rule sets #2 switched to DNS is
    // refused until they are removed; the saved DNS rule has none left.
    await check(`${version} routing rule with Built-in rule sets #2 switched to DNS`, async () => {
      const fixture = rule({ action: 'connection', ...routed, community_lists: ['youtube'],
        rule_set_with_subnets: [VALVE] });
      const env = createEnvironment({ version, config: { rule: fixture } });
      const modal = await env.openRule('rule');
      modal.option('action').getUIElement('rule').setValue('dns');
      modal.option('dns_server').getUIElement('rule').setValue('1.1.1.1');
      await assert.rejects(modal.save(), SECONDARY_ON_DNS);
      assert.deepEqual(env.uci.data.rule, fixture, 'a refused save changed UCI');
      assert.equal(modal.active('secondary_rule_sets'), true, 'the values to remove must stay visible');

      modal.option('secondary_rule_sets').getUIElement('rule').setValue([]);
      await modal.save();
      assert.deepEqual(env.uci.data.rule, rule({ action: 'dns', community_lists: ['youtube'],
        dns_type: 'udp', dns_server: '1.1.1.1', dns_detour_enabled: '0' }));

      // Values picked in this editor only, before switching, are hidden and not saved.
      const fresh = createEnvironment({ version, config: { rule: rule({ action: 'connection', ...routed,
        community_lists: ['youtube'] }) } });
      const freshModal = await fresh.openRule('rule');
      freshModal.option('secondary_rule_sets').getUIElement('rule').setValue(['valve']);
      freshModal.option('action').getUIElement('rule').setValue('dns');
      freshModal.option('dns_server').getUIElement('rule').setValue('1.1.1.1');
      await freshModal.save();
      assert.equal(freshModal.active('secondary_rule_sets'), false);
      assert.equal(fresh.uci.data.rule.action, 'dns');
      assert.equal(fresh.uci.data.rule.rule_set_with_subnets, undefined);
    });

    // A rule switched to DNS drops the destination IPs and ports it no
    // longer uses (only a DNS rule saved as it is keeps them).
    await check(`${version} routing rule with IPs and ports switched to DNS`, async () => {
      const env = createEnvironment({ version, config: { rule: rule({ action: 'block', domain: 'example.net',
        ip_cidr: '10.0.0.0/8', ports: ['443'] }) } });
      const modal = await env.openRule('rule');
      modal.option('action').getUIElement('rule').setValue('dns');
      modal.option('dns_server').getUIElement('rule').setValue('1.1.1.1');
      await modal.save();
      assert.deepEqual(env.uci.data.rule, rule({ action: 'dns', domain: 'example.net', dns_type: 'udp',
        dns_server: '1.1.1.1', dns_detour_enabled: '0' }));
    });

    // A refused save writes nothing. LuCI parses every option even when one
    // is invalid; the writes and removals of the others (DNS fields of the
    // new action, routing ports and links) must not stay behind for the next
    // modal save or, after Dismiss, for Save & Apply (UC-008, UC-046).
    for (const [name, fixture, dnsServer, error] of [
      ['block rule with Built-in rule sets #2', rule({ action: 'block', community_lists: ['youtube'],
        ports: ['443'], ip_cidr: '10.0.0.0/8', rule_set_with_subnets: [VALVE] }), '1.1.1.1', SECONDARY_ON_DNS],
      ['connection rule with Built-in rule sets #2', rule({ action: 'connection', ...routed,
        community_lists: ['youtube'], selector_proxy_links: ['socks5://10.0.0.1:1080'], ports: ['443'],
        rule_set_with_subnets: [VALVE] }), '1.1.1.1', SECONDARY_ON_DNS],
      ['connection rule without a DNS server', rule({ action: 'connection', ...routed,
        community_lists: ['youtube'], selector_proxy_links: ['socks5://10.0.0.1:1080'], ports: ['443'],
        ip_cidr: '10.0.0.0/8' }), '', /DNS server address cannot be empty/],
    ]) await check(`${version} ${name}: refused switch to DNS writes nothing`, async () => {
      const env = createEnvironment({ version, config: { rule: fixture } });
      const modal = await env.openRule('rule');
      const action = modal.option('action').getUIElement('rule');
      action.setValue('dns');
      modal.option('dns_server').getUIElement('rule').setValue(dnsServer);
      await assert.rejects(modal.save(), error);
      assert.deepEqual(env.uci.data.rule, fixture, 'a refused save changed UCI');

      // Choosing the old action again, as the message suggests, saves nothing new.
      action.setValue(fixture.action);
      await modal.save();
      assert.deepEqual(env.uci.data.rule, fixture, 'switching back changed the rule');
    });

    // Refusals that LuCI's parse reaches only after the other options have
    // written or removed their values (the backend strategy check, the item
    // lists of the new action) are checked before the save as well: nothing
    // is written, and switching back saves the rule as it was (UC-008, UC-040).
    const connectionWithSubscription = {
      rule: rule({ action: 'connection', ...routed, community_lists: ['youtube'],
        selector_proxy_links: ['socks5://10.0.0.1:1080'], ports: ['443'], subscription_url: ['sub'] }),
      sub: { '.name': 'sub', '.type': 'subscription_url', '.anonymous': false, section: 'rule',
        url: 'https://example.com/sub', subscription_update_enabled: '1', subscription_update_interval: '4h' },
    };
    const strategyCommands = {
      nfqws_opt: 'validate_nfqws_strategy_json',
      nfqws2_opt: 'validate_nfqws2_strategy_json',
      byedpi_cmd_opts: 'validate_byedpi_strategy_json',
    };
    const backend = (answers) => ({
      exec(_command, args) {
        const answer = args && Object.values(strategyCommands).includes(args[0]) ? answers[args[0]] : null;
        return Promise.resolve(answer || { code: 0, stdout: '{}', stderr: '' });
      },
    });
    const rejected = { code: 0, stdout: '{"valid":false,"message":"Rejected by the backend parser"}', stderr: '' };
    const unavailable = { code: 1, stdout: '', stderr: 'timeout' };
    for (const [action, strategy, value] of [
      ['zapret', 'nfqws_opt', '--filter-tcp=443 --dpi-desync=fake --new --filter-udp=443'],
      ['zapret2', 'nfqws2_opt', '--filter-tcp=443 --lua-desync=fake:blob=fake_default_tls'],
      ['byedpi', 'byedpi_cmd_opts', '-o 1 -d 2'],
    ]) for (const [label, answer, error] of [
      ['strategy rejected by the backend', rejected, /Rejected by the backend parser/],
      ['backend check unavailable', unavailable, /Backend validation unavailable/],
    ]) await check(`${version} connection rule switched to ${action}, ${label}: refused save writes nothing`, async () => {
      const config = JSON.parse(JSON.stringify(connectionWithSubscription));
      const env = createEnvironment({ version, config, fs: backend({ [strategyCommands[strategy]]: answer }) });
      const modal = await env.openRule('rule');
      const actionWidget = modal.option('action').getUIElement('rule');
      actionWidget.setValue(action);
      modal.option(strategy).getUIElement('rule').setValue(value);
      await assert.rejects(modal.save(), error);
      assert.deepEqual(env.uci.data, connectionWithSubscription, 'a refused save changed UCI');
      assert.equal(modal.map.root.querySelector('.fkp-rule-save-refusal'), null,
        'the strategy field shows the refusal itself');

      actionWidget.setValue('connection');
      await modal.save();
      assert.deepEqual(env.uci.data, connectionWithSubscription, 'switching back changed the rule');
    });

    // The rule keeps its action: ports edited next to a changed strategy wait
    // for the backend check too.
    await check(`${version} zapret rule: strategy check unavailable, edited ports are not written`, async () => {
      const fixture = rule({ action: 'zapret', ...routed, nfqws_opt: '--filter-tcp=443 --dpi-desync=fake',
        community_lists: ['youtube'], ports: ['443'] });
      const env = createEnvironment({ version, config: { rule: fixture },
        fs: backend({ validate_nfqws_strategy_json: unavailable }) });
      const modal = await env.openRule('rule');
      modal.option('nfqws_opt').getUIElement('rule').setValue('--filter-tcp=443 --dpi-desync=fake,multisplit');
      modal.option('ports').getUIElement('rule').setValue(['8443']);
      await assert.rejects(modal.save(), /Backend validation unavailable/);
      assert.deepEqual(env.uci.data.rule, fixture, 'a refused save changed UCI');
    });

    for (const [label, option, items, error] of [
      ['a priority without settings', 'priority_group', ['pg_new'], /Open priority settings/],
      ['an invalid JSON outbound', 'outbound_jsons', ['{"type":"vless"}'], /non-empty tag/],
    ]) await check(`${version} dns rule switched to connection with ${label}: refused save writes nothing`, async () => {
      const fixture = rule({ action: 'dns', dns_type: 'udp', dns_server: '8.8.8.8', dns_detour_enabled: '0',
        domain: 'example.net' });
      const env = createEnvironment({ version, config: { rule: fixture } });
      const modal = await env.openRule('rule');
      const actionWidget = modal.option('action').getUIElement('rule');
      actionWidget.setValue('connection');
      // The rule gets a connection, so the refusal is the one of the items.
      if (option !== 'outbound_jsons')
        modal.option('selector_proxy_links').getUIElement('rule').setValue(['socks5://10.0.0.1:1080']);
      modal.option(option).getUIElement('rule').setValue(items);
      await assert.rejects(modal.save(), error);
      assert.deepEqual(env.uci.data.rule, fixture, 'a refused save changed UCI');

      // LuCI drops the refusal of the modal Save, and no field shows the
      // items of a list as invalid: the modal says why it was not saved.
      const refusal = () => modal.map.root.querySelector('.fkp-rule-save-refusal');
      await modal.saveButton();
      assert.match(refusal()?.textContent || '', error, 'the refusal must be shown in the modal');
      assert.deepEqual(env.uci.data.rule, fixture, 'a refused save changed UCI');

      actionWidget.setValue('dns');
      await modal.save();
      assert.deepEqual(env.uci.data.rule, fixture, 'switching back changed the rule');
      assert.equal(refusal(), null, 'a save that passes must clear the refusal');
    });

    // The modal stays editable, and Dismiss works, while the backend checks
    // of a Save run. What parse writes is what was checked: a form edited
    // meanwhile is checked again, and a Save whose modal was dismissed
    // writes nothing (UC-008, UC-040).
    const S1 = '--filter-tcp=443 --dpi-desync=fake';
    const S2 = '--filter-tcp=443 --dpi-desync=fake,multisplit';
    const pendingBackend = (answers) => {
      let release;
      const pending = new Promise((resolve) => { release = resolve; });
      const fs = {
        exec(_command, args) {
          if (args && args[0] === 'validate_nfqws_strategy_json')
            return args[1] === S1 ? pending : Promise.resolve(answers[args[1]]);
          return Promise.resolve({ code: 0, stdout: '{}', stderr: '' });
        },
      };
      return { fs, release: () => release({ code: 0, stdout: '{"valid":true}', stderr: '' }) };
    };
    const tick = () => new Promise((resolve) => setImmediate(resolve));
    const accepted = { code: 0, stdout: '{"valid":true}', stderr: '' };
    for (const [label, answer, edit, error] of [
      ['strategy edited to one the backend rejects', rejected,
        (modal) => modal.option('nfqws_opt').getUIElement('rule').setValue(S2), /Rejected by the backend parser/],
      ['strategy edited while the backend is unavailable', unavailable,
        (modal) => modal.option('nfqws_opt').getUIElement('rule').setValue(S2), /Backend validation unavailable/],
      ['another field made invalid', accepted,
        (modal) => modal.option('ip_cidr').getUIElement('rule').setValue('not-an-ip'), /invalid input value/],
    ]) await check(`${version} ${label} during the pending strategy check: refused save writes nothing`, async () => {
      const backendState = pendingBackend({ [S2]: answer });
      const env = createEnvironment({ version, config: JSON.parse(JSON.stringify(connectionWithSubscription)),
        fs: backendState.fs });
      const modal = await env.openRule('rule');
      modal.option('action').getUIElement('rule').setValue('zapret');
      modal.option('nfqws_opt').getUIElement('rule').setValue(S1);
      const saving = modal.save();
      await tick();
      edit(modal);
      backendState.release();
      await assert.rejects(saving, error);
      assert.deepEqual(env.uci.data, connectionWithSubscription, 'a refused save changed UCI');
    });

    await check(`${version} strategy edited during the pending check: the edited value is checked and saved`, async () => {
      const backendState = pendingBackend({ [S2]: accepted });
      const env = createEnvironment({ version, config: JSON.parse(JSON.stringify(connectionWithSubscription)),
        fs: backendState.fs });
      const modal = await env.openRule('rule');
      modal.option('action').getUIElement('rule').setValue('zapret');
      modal.option('nfqws_opt').getUIElement('rule').setValue(S1);
      const saving = modal.save();
      await tick();
      modal.option('nfqws_opt').getUIElement('rule').setValue(S2);
      backendState.release();
      await saving;
      assert.equal(env.uci.data.rule.action, 'zapret');
      assert.equal(env.uci.data.rule.nfqws_opt, S2);
    });

    await check(`${version} Dismiss during the pending strategy check: the late save writes nothing`, async () => {
      const backendState = pendingBackend({});
      const env = createEnvironment({ version, config: JSON.parse(JSON.stringify(connectionWithSubscription)),
        fs: backendState.fs });
      const modal = await env.openRule('rule');
      modal.option('action').getUIElement('rule').setValue('zapret');
      modal.option('nfqws_opt').getUIElement('rule').setValue(S1);
      const saving = modal.saveButton();
      await tick();
      await modal.dismiss();
      backendState.release();
      await saving;
      assert.deepEqual(env.uci.data, connectionWithSubscription, 'a dismissed modal changed UCI');
      assert.deepEqual([env.uci.state.changes, env.uci.state.deletes, env.uci.state.creates], [{}, {}, {}],
        'a dismissed modal left staged edits');
    });

    // UC-003: the device filter is offered whenever a Built-in rule set #2 is set.
    await check(`${version} device filter visibility`, async () => {
      const env = createEnvironment({ version, config: { rule: fixtures.device_filter_secondary_only } });
      const modal = await env.openRule('rule');
      assert.equal(modal.active('source_ip_cidr'), true,
        `${version}: Device filter must be shown for a rule with Built-in rule sets #2`);

      // A rule without any destination condition still hides the device filter.
      const bare = createEnvironment({ version, config: { rule: rule({ action: 'block',
        source_ip_cidr: ['192.168.1.50'] }) } });
      assert.equal((await bare.openRule('rule')).active('source_ip_cidr'), false,
        `${version}: Device filter must stay hidden without destination conditions`);
    });

    // A hidden device filter is kept only while legacy remote lists (no widget)
    // still match; removing the last destination condition clears it, and a
    // visible device filter can always be cleared.
    for (const [label, values, edit, expected] of [
      ['last condition removed', { community_lists: ['youtube'] },
        { community_lists: [] }, undefined],
      ['last visible condition removed, legacy list left',
        { community_lists: ['youtube'], remote_domain_lists: ['https://example.com/domains.lst'] },
        { community_lists: [] }, ['192.168.1.50']],
      ['visible filter cleared next to legacy list',
        { community_lists: ['youtube'], remote_domain_lists: ['https://example.com/domains.lst'] },
        { source_ip_cidr: [] }, undefined],
    ]) await check(`${version} device filter: ${label}`, async () => {
      const env = createEnvironment({ version, config: { rule: rule({ action: 'block', ...values,
        source_ip_cidr: ['192.168.1.50'] }) } });
      const modal = await env.openRule('rule');
      for (const [name, value] of Object.entries(edit))
        modal.option(name).getUIElement('rule').setValue(value);
      await modal.save();
      assert.deepEqual(env.uci.data.rule.source_ip_cidr, expected);
    });

    // UC-004: the item settings modal of a user rule set keeps Built-in #2.
    for (const [include, expected] of [
      ['0', { rule_set: [CUSTOM], rule_set_with_subnets: [CUSTOM_SUBNETS, VALVE] }],
      ['1', { rule_set_with_subnets: [CUSTOM_SUBNETS, VALVE, CUSTOM] }],
    ]) await check(`${version} include_subnets=${include}`, async () => {
      const fixture = fixtures.mixed_subnet_rule_sets;
      const env = createEnvironment({ version, config: { rule: fixture } });
      const modal = await env.openRule('rule');
      const settings = await modal.openItemSettings('rule_set', CUSTOM);
      settings.setValue('include_subnets', include);
      await settings.save();
      const { rule_set, rule_set_with_subnets, ...rest } = fixture;
      const after = Object.assign({}, rest, expected);
      assert.deepEqual(env.uci.data.rule, after,
        `${version}: include_subnets=${include} for a user rule set changed other rule sets`);
      await modal.save();
      assert.deepEqual(env.uci.data.rule, after,
        `${version}: include_subnets=${include}: the rule save changed the rule sets`);
    });

    // Turning subnets off for a user set also keeps Built-in #2.
    await check(`${version} include_subnets off`, async () => {
      const fixture = fixtures.mixed_subnet_rule_sets;
      const env = createEnvironment({ version, config: { rule: fixture } });
      const modal = await env.openRule('rule');
      const settings = await modal.openItemSettings('rule_set', CUSTOM_SUBNETS);
      settings.setValue('include_subnets', '0');
      await settings.save();
      await modal.save();
      assert.deepEqual(env.uci.data.rule.rule_set, [CUSTOM, CUSTOM_SUBNETS]);
      assert.deepEqual(env.uci.data.rule.rule_set_with_subnets, [VALVE],
        `${version}: disabling subnets for a user rule set dropped Built-in rule sets #2`);
    });
  }
  if (failures.length) {
    console.error(failures.join('\n\n'));
    process.exit(1);
  }
  console.log('luci_rule_roundtrip: PASS');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
