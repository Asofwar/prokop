#!/usr/bin/env bash
set -euo pipefail

# Legacy rule settings in the rule modal (UC-042, UC-043, D-6 a). The real
# section.js runs under node (tests/helpers/luci_form_harness.js); the real
# sing-box generator, validator and the firewall's condition readers report
# what they build from the UCI state before and after.
# - The "Legacy settings" notice names every legacy option of the rule and
#   what the backend does with it; a plain save keeps them (no silent
#   migration).
# - Convert… previews exactly which options are set, added and removed and
#   asks first; Cancel and Dismiss change nothing. Confirmed and saved, the
#   rule keeps only the options the editor writes, and the generated sing-box
#   configuration is byte-for-byte the same, the validator verdict and the
#   firewall's IP, device and port sets are the same.
# - Values the current form cannot hold unchanged block the conversion.
# - Downloaded lists are shown and kept; unsupported podkop matchers can be
#   removed after a confirmation, which makes the rule valid again.
# - A read-only role sees only that legacy settings exist.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers" "$ROOT_DIR/prokop/files/usr/lib" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const [helpers, LIB] = process.argv.slice(2);
const { createEnvironment } = require(`${helpers}/luci_form_harness.js`);
const backend = require(`${helpers}/uci_backend.js`);

function rule(values) {
  return Object.assign({ '.name': 'rule', '.type': 'section', '.anonymous': false, enabled: '1' }, values);
}
const routed = { mixed_proxy_enabled: '0' };
const DNS = { action: 'dns', dns_type: 'udp', dns_server: '1.1.1.1', dns_detour_enabled: '0' };
const iface = (name, extra) => Object.assign({ '.name': name, '.type': 'section_interface', '.anonymous': true,
  section: 'rule', domain_resolver_enabled: '0', domain_resolver_dns_type: 'udp',
  domain_resolver_dns_server: '8.8.8.8' }, extra);

// Options the editor does not write (or, for the interface list, shows).
const LEGACY = ['domain_suffix', 'domain_suffix_text', 'domain_suffix_text_mode', 'domain_keyword', 'domain_regex',
  'domain_text', 'domain_keyword_text', 'domain_regex_text', 'domain_text_mode', 'domain_keyword_text_mode',
  'domain_regex_text_mode', 'ip_cidr_text', 'ip_cidr_text_mode', 'source_ip_cidr_text', 'source_ip_cidr_text_mode',
  'excluded_source_ip_cidr_text', 'excluded_source_ip_cidr_text_mode', 'conditions_text_mode', 'ports_text',
  'fully_routed_ips_text', 'interfaces', 'interface', 'interface_settings', 'domain_resolver_enabled',
  'domain_resolver_dns_type', 'domain_resolver_dns_server'];
const legacyOptions = (section) => Object.keys(section).filter((key) => LEGACY.includes(key) ||
  (['domain', 'ip_cidr'].includes(key) && Array.isArray(section[key])) ||
  (section.action === 'dns' && ['ip_cidr', 'ports'].includes(key)));

const convertible = {
  exact_domain_list: { rule: rule({ action: 'block', domain: ['exact.example', 'Second.Example'] }) },
  keyword_regex_lists: { rule: rule({ action: 'block', domain: 'example.com\n# work\nfull:a.example',
    domain_keyword: ['video'], domain_regex: ['^ads\\.'], domain_keyword_text: 'music' }) },
  keyword_text_mode: { rule: rule({ action: 'block', domain: 'example.com', domain_keyword: ['video'],
    domain_keyword_text: 'music', domain_keyword_text_mode: '1' }) },
  domain_text_forms: { rule: rule({ action: 'bypass', domain_text: 'exact.example', domain_suffix: ['suffix.example',
    'keyword:tube'], domain_suffix_text: 'other.example // note', domain_suffix_text_mode: '0',
    domain_regex_text: '^cdn[0-9]+\\.', domain_regex_text_mode: '0' }) },
  ip_text_mode: { rule: rule({ action: 'block', ip_cidr: ['1.1.1.1'], ip_cidr_text: '8.8.8.8\n9.9.9.0/24 # dns',
    ip_cidr_text_mode: '1' }) },
  ip_list: { rule: rule({ action: 'bypass', ip_cidr: ['10.0.0.0/8', '192.0.2.1'], ports: ['443'] }) },
  ip_text_fallback: { rule: rule({ action: 'block', ip_cidr_text: '8.8.4.4, 9.9.9.9' }) },
  ip_option_shadows_text: { rule: rule({ action: 'block', ip_cidr: '10.1.0.0/16', ip_cidr_text: '8.8.8.8' }) },
  source_text_mode: { rule: rule({ action: 'block', domain: 'example.com', source_ip_cidr: ['192.168.1.2'],
    source_ip_cidr_text: '192.168.1.3 192.168.1.4', source_ip_cidr_text_mode: '1' }) },
  device_text_fallback: { rule: rule({ action: 'bypass', domain: 'example.com',
    source_ip_cidr_text: '192.168.1.5', excluded_source_ip_cidr_text: '192.168.1.6, 192.168.1.7' }) },
  conditions_text_mode: { rule: rule({ action: 'block', domain: 'example.com', domain_keyword: ['video'],
    domain_keyword_text: 'music', ip_cidr: ['1.1.1.1'], ip_cidr_text: '8.8.8.8', source_ip_cidr: ['192.168.1.2'],
    source_ip_cidr_text: '192.168.1.3', excluded_source_ip_cidr: ['192.168.1.8'],
    excluded_source_ip_cidr_text: '192.168.1.9', conditions_text_mode: '1' }) },
  ports_text: { rule: rule({ action: 'block', domain: 'example.com', ports: ['443', '80'],
    ports_text: '80 8000-8080 bad, 53' }) },
  fully_routed_text: { rule: rule({ action: 'bypass', ip_cidr: '10.0.0.0/8', fully_routed_ips: ['192.168.1.70'],
    fully_routed_ips_text: '192.168.1.7' }) },
  dns_legacy: { rule: rule({ ...DNS, domain_keyword_text: 'video', source_ip_cidr_text: '192.168.1.3',
    ip_cidr_text: '8.8.8.8', ports_text: '53' }) },
  // DNS rules match domains and devices only.
  dns_ip_ports: { rule: rule({ ...DNS, domain: 'example.com', ip_cidr: '10.0.0.0/8', ports: ['443'] }) },
  dns_ip_list: { rule: rule({ ...DNS, domain: 'example.com', ip_cidr: ['1.1.1.1'], ports_text: '53' }) },
  legacy_interfaces: { rule: rule({ action: 'connection', ...routed, domain: 'example.com',
    interfaces: ['awg0', 'wg1'], domain_resolver_enabled: '1', domain_resolver_dns_server: '9.9.9.9',
    interface_settings: JSON.stringify({ wg1: { domain_resolver_enabled: '1', domain_resolver_dns_type: 'dot',
      domain_resolver_dns_server: '1.1.1.1' } }) }) },
  legacy_interface_option: { rule: rule({ action: 'connection', ...routed, domain: 'example.com',
    interface: 'awg0' }) },
  // config/connections.uc bool_value(): a JSON false or 0 in interface_settings
  // reads as unset (ucode compares both equal to ""), so the rule option
  // applies; a list as the rule option is never true.
  interface_settings_false: { rule: rule({ action: 'connection', ...routed, domain: 'example.com',
    interfaces: ['awg0', 'wg1'], domain_resolver_enabled: '1', domain_resolver_dns_server: '9.9.9.9',
    interface_settings: '{"awg0":{"domain_resolver_enabled":false},"wg1":{"domain_resolver_enabled":0}}' }) },
  interface_settings_true: { rule: rule({ action: 'connection', ...routed, domain: 'example.com',
    interfaces: ['awg0', 'wg1'], domain_resolver_dns_server: '9.9.9.9',
    interface_settings: '{"awg0":{"domain_resolver_enabled":true},"wg1":{"domain_resolver_enabled":1}}' }) },
  resolver_flag_list: { rule: rule({ action: 'connection', ...routed, domain: 'example.com',
    interfaces: ['awg0'], domain_resolver_enabled: ['1'], domain_resolver_dns_server: '9.9.9.9' }) },
  legacy_interfaces_shadowed: {
    rule: rule({ action: 'connection', ...routed, domain: 'example.com', interfaces: ['awg0'], interface: 'wg9' }),
    if1: iface('if1', { name: 'wg0' }),
  },
  legacy_interfaces_not_connection: { rule: rule({ action: 'block', domain: 'example.com',
    interfaces: ['awg0'] }) },
  remote_and_text: { rule: rule({ action: 'block', remote_domain_lists: ['https://example.com/domains.srs'],
    domain_suffix_text: 'example.org' }) },
  // The device field is hidden without a destination condition it shows;
  // the converted device list stays for the downloaded list.
  remote_and_devices: { rule: rule({ action: 'block', remote_subnet_lists: ['https://example.com/subnets.srs'],
    source_ip_cidr_text: '192.168.1.5' }) },
  // Without a destination condition the rule does not use a device filter
  // (sing-box and nft match devices only together with one), the field is
  // hidden and a save drops it: the conversion removes the legacy devices
  // and says so instead of moving them to the field.
  devices_without_destination: { rule: rule({ action: 'block', source_ip_cidr_text: '192.168.1.5' }) },
  interfaces_devices_without_destination: { rule: rule({ action: 'connection', ...routed, interfaces: ['awg0'],
    source_ip_cidr_text: '192.168.1.5', source_ip_cidr_text_mode: '1' }) },
};
const devicesUnused = new Set(['devices_without_destination', 'interfaces_devices_without_destination']);

// Values the current form cannot hold as they are: no conversion.
const blocked = {
  keyword_with_space: [{ rule: rule({ action: 'block', domain_keyword: ['two words'] }) }, /two words/],
  regex_with_comma: [{ rule: rule({ action: 'block', domain_regex: ['^a{1,3}\\.example$'] }) }, /\^a\{1,3\}/],
  prefixed_exact: [{ rule: rule({ action: 'block', domain: ['full:a.example'] }) }, /full:a\.example/],
  switch_read_differently: [{ rule: rule({ action: 'block', ip_cidr: ['1.1.1.1'], ip_cidr_text: '8.8.8.8',
    ip_cidr_text_mode: 'true' }) }, /ip_cidr_text_mode.*true/],
  duplicate_interfaces: [{ rule: rule({ action: 'connection', ...routed, domain: 'example.com',
    interfaces: ['awg0', 'awg0'] }) }, /awg0/],
  invalid_domain: [{ rule: rule({ action: 'block', domain: ['bad_domain!'] }) }, /bad_domain!/],
};

// The firewall's view (nft/apply.uc section_rule_condition_csv(),
// section_rule_ports_csv()): which sets it fills for every rule. Destination
// IP and port sets exist only for the actions that capture or bypass traffic
// (section_priority_action()); device sources also feed source-aware DNS.
const NFT_SCRIPT = `
let common = require("core.common");
let rule_config = require("config.rule");
let data = json(require("fs").readfile(ARGV[0]));
function combined_text(s) {
    if (type(s.domain) != "array") {
        let value = common.option(s, "domain", "");
        if (value != "")
            return value;
    }
    return common.option(s, "domain_suffix_text", "");
}
function csv(s, key, kind) {
    return rule_config.rule_condition_csv_value(key, kind, common.option(s, key + "_text_mode", "0"),
        common.option(s, "conditions_text_mode", "0"), common.option(s, key + "_text", ""),
        common.option(s, key, ""), combined_text(s), common.option(s, "domain_suffix", ""));
}
function set(value) {
    let result = {};
    for (let item in split(value, ","))
        if (item != "")
            result[item] = true;
    return sort(keys(result));
}
const PRIORITY_ACTIONS = [ "connection", "proxy", "outbound", "vpn", "block", "zapret", "zapret2", "byedpi", "bypass" ];
let out = {};
for (let s in (data.section || [])) {
    let priority = index(PRIORITY_ACTIONS, common.option(s, "action", "")) >= 0;
    out[s[".name"]] = {
        domains: csv(s, "domain", "domains") != "" || csv(s, "domain_suffix", "domains") != "" ||
            csv(s, "domain_keyword", "generic") != "" || csv(s, "domain_regex", "generic") != "",
        ip_cidr: priority ? set(csv(s, "ip_cidr", "subnets")) : null,
        source_ip_cidr: set(csv(s, "source_ip_cidr", "subnets")),
        excluded_source_ip_cidr: set(csv(s, "excluded_source_ip_cidr", "subnets")),
        ports: priority ? set(rule_config.rule_ports_csv_value(common.option(s, "ports", ""),
            common.option(s, "ports_text", ""))) : null
    };
}
print(sprintf("%J\\n", out));
`;
function firewallConditions(data) {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'prokop-legacy-nft-'));
  try {
    fs.writeFileSync(path.join(work, 'fixture.json'), JSON.stringify(backend.fixtureFromUci(data)));
    fs.writeFileSync(path.join(work, 'nft.uc'), NFT_SCRIPT);
    return JSON.parse(execFileSync('ucode', ['-L', LIB, path.join(work, 'nft.uc'),
      path.join(work, 'fixture.json')]).toString());
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

const buttons = (node) => node.querySelectorAll('button');
const button = (node, label) => {
  const found = buttons(node).find((b) => b.textContent === label);
  assert(found, `no "${label}" button in: ${node.textContent}`);
  return found;
};
const hasButton = (node, label) => buttons(node).some((b) => b.textContent === label);
// The list items of the notice: findings ("key = value — effect"), preview
// lines ("set key: value", "add the interface item name", "remove a, b").
const lines = (node) => node.querySelectorAll('li').map((li) => li.textContent);
const names = (node, key) => lines(node).some((line) => line.startsWith(`${key} = `));
const removed = (node) => lines(node).filter((line) => line.startsWith('remove '))
  .flatMap((line) => line.slice('remove '.length).split(', '));
const changed = (node, key) => removed(node).includes(key) ||
  lines(node).some((line) => line.startsWith(`set ${key}: `));

const failures = [];
async function check(label, fn) {
  try {
    await fn();
  } catch (error) {
    failures.push(`${label}: ${error.message}`);
  }
}

// Opens the rule and returns the modal with its rendered legacy notice.
async function openNotice(version, config, options) {
  const env = createEnvironment({ version, config });
  const modal = await env.openRule('rule', options);
  assert.equal(modal.active('_legacy_conditions'), true, 'the legacy notice must be shown');
  return { env, modal, notice: modal.option('_legacy_conditions').renderWidget('rule') };
}

(async () => {
  for (const version of ['24.10', '25.12']) {
    for (const [name, config] of Object.entries(convertible)) {
      const found = legacyOptions(config.rule);

      await check(`${version} ${name}: notice and plain save`, async () => {
        const { env, modal, notice } = await openNotice(version, config);
        for (const key of found) assert(names(notice, key), `the notice does not name ${key}: ${lines(notice)}`);
        assert.match(notice.textContent, /legacy/);
        await modal.save();
        assert.deepEqual(env.uci.data, config, 'a plain save changed UCI');
      });

      await check(`${version} ${name}: preview and cancel`, async () => {
        const { env, modal, notice } = await openNotice(version, config);
        button(notice, 'Convert…').attrs.click();
        for (const key of found)
          assert(removed(notice).includes(key) || changed(notice, key), `the preview does not replace ${key}`);
        button(notice, 'Cancel').attrs.click();
        await modal.save();
        assert.deepEqual(env.uci.data, config, 'a cancelled conversion changed UCI');
      });

      await check(`${version} ${name}: converted`, async () => {
        const { env, modal, notice } = await openNotice(version, config);
        button(notice, 'Convert…').attrs.click();
        const preview = notice.querySelector('div.fkp-legacy-settings__actions');
        const previewLines = lines(preview);
        button(notice, 'Convert').attrs.click();
        assert.match(notice.textContent, /converted/);
        assert.equal(hasButton(notice, 'Convert…'), false, 'nothing left to convert');
        // The Network Interface field lists the items the legacy list became.
        const created = env.uci.sections('prokop', 'section_interface')
          .filter((item) => !config[item['.name']]).map((item) => item['.name']);
        if (created.length)
          assert.deepEqual(modal.option('interfaces').formvalue('rule'), created, 'the field must list the new items');
        await modal.save();
        const after = env.uci.data;

        assert.deepEqual(legacyOptions(after.rule), [], 'legacy options left after the conversion');
        // The preview named every option that changed and every item added.
        for (const key of new Set([...Object.keys(config.rule), ...Object.keys(after.rule)]))
          if (JSON.stringify(config.rule[key]) !== JSON.stringify(after.rule[key]))
            assert(changed(preview, key), `the preview does not mention ${key}: ${previewLines}`);
        // What the preview sets and removes is what the save stores.
        const shown = (value) => (Array.isArray(value) ? value : `${value ?? ''}`.split('\n'))
          .map((item) => `${item}`.trim()).filter(Boolean).join(', ');
        previewLines.filter((line) => line.startsWith('set ')).forEach((line) => {
          const key = line.slice('set '.length, line.indexOf(': '));
          assert.equal(`set ${key}: ${shown(after.rule[key])}`, line, 'the save stored another value');
        });
        for (const key of removed(preview))
          assert.equal(after.rule[key], undefined, `the preview removes ${key}, the save kept it`);
        const added = Object.values(after).filter((s) => !config[s['.name']]);
        for (const item of added)
          assert(previewLines.some((line) => line.startsWith(`add the interface item ${item.name}`)),
            `the preview does not add ${item.name}: ${previewLines}`);

        const generated = [backend.generate(config), backend.generate(after)];
        assert.equal(generated[1].ok, generated[0].ok, generated[1].error || generated[0].error);
        assert.equal(generated[0].ok, true, `the fixture must generate: ${generated[0].error}`);
        assert.equal(generated[1].text, generated[0].text, 'the generated sing-box configuration changed');
        assert.equal(backend.validate(after).ok, backend.validate(config).ok, 'the validator verdict changed');
        const firewall = [firewallConditions(config), firewallConditions(after)];
        if (devicesUnused.has(name)) {
          // nft matches the device set only together with destination or
          // DNS conditions, which the rule has none of.
          assert(previewLines.some((line) => /no destination condition/.test(line)),
            `the preview does not say why the devices go: ${previewLines}`);
          assert.equal(firewall[0].rule.domains, false);
          assert.deepEqual([firewall[0].rule.ip_cidr, firewall[0].rule.ports], [[], []]);
          assert.deepEqual(firewall[1].rule.source_ip_cidr, []);
          firewall.forEach((sets) => delete sets.rule.source_ip_cidr);
        }
        assert.deepEqual(firewall[1], firewall[0], 'the firewall sets changed');

        // Opened again, only what cannot be converted is left, and a plain
        // save keeps the converted rule as it is.
        const again = createEnvironment({ version, config: after });
        const reopened = await again.openRule('rule');
        assert.equal(reopened.active('_legacy_conditions'),
          ['remote_domain_lists', 'remote_subnet_lists'].some((key) => after.rule[key]));
        await reopened.save();
        assert.deepEqual(again.uci.data, after, 'a plain save of the converted rule changed UCI');
      });

      await check(`${version} ${name}: dismissed`, async () => {
        const { env, modal, notice } = await openNotice(version, config);
        button(notice, 'Convert…').attrs.click();
        button(notice, 'Convert').attrs.click();
        await modal.dismiss();
        assert.deepEqual(env.uci.data, config, 'Dismiss must discard the conversion');
      });
    }

    // After the conversion the Network Interface field edits the new items
    // like any others: an item removed there is gone after the save.
    await check(`${version} legacy_interfaces: edited after the conversion`, async () => {
      const config = convertible.legacy_interfaces;
      const { env, modal, notice } = await openNotice(version, config);
      button(notice, 'Convert…').attrs.click();
      button(notice, 'Convert').attrs.click();
      const field = modal.option('interfaces').getUIElement('rule');
      field.setValue(field.getValue().slice(1));
      await modal.save();
      const items = Object.values(env.uci.data).filter((item) => item['.type'] === 'section_interface');
      assert.deepEqual(items.map((item) => item.name), ['wg1']);
      assert.deepEqual(legacyOptions(env.uci.data.rule), []);
    });

    // Interfaces put in the Network Interface field in this window before
    // the conversion stay there next to the converted items, one entry per
    // interface.
    await check(`${version} legacy_interfaces: field edited before the conversion`, async () => {
      const config = convertible.legacy_interfaces;
      const { env, modal, notice } = await openNotice(version, config);
      const field = modal.option('interfaces').getUIElement('rule');
      field.setValue(['wg9', 'awg0']);
      button(notice, 'Convert…').attrs.click();
      button(notice, 'Convert').attrs.click();
      const created = env.uci.sections('prokop', 'section_interface').map((item) => item['.name']);
      assert.deepEqual(field.getValue(), [...created, 'wg9'], 'the field must keep what the user added');
      await modal.save();
      const items = Object.values(env.uci.data).filter((item) => item['.type'] === 'section_interface');
      assert.deepEqual(items.map((item) => [item.name, item.domain_resolver_enabled, item.domain_resolver_dns_type,
        item.domain_resolver_dns_server]), [['awg0', '1', 'udp', '9.9.9.9'], ['wg1', '1', 'dot', '1.1.1.1'],
        ['wg9', '0', 'udp', '8.8.8.8']]);
      assert.deepEqual(legacyOptions(env.uci.data.rule), []);
    });

    // A destination condition added before Convert… shows the Device filter
    // field: the devices move there and the save keeps them.
    await check(`${version} devices with a destination added in the form`, async () => {
      const config = convertible.devices_without_destination;
      const { env, modal, notice } = await openNotice(version, config);
      assert.equal(modal.active('source_ip_cidr'), false);
      modal.option('domain').getUIElement('rule').setValue('example.com');
      modal.map.checkDepends();
      assert.equal(modal.active('source_ip_cidr'), true);
      button(notice, 'Convert…').attrs.click();
      const preview = lines(notice.querySelector('div.fkp-legacy-settings__actions'));
      assert.deepEqual(preview, ['set source_ip_cidr: 192.168.1.5', 'remove source_ip_cidr_text']);
      button(notice, 'Convert').attrs.click();
      await modal.save();
      assert.deepEqual(env.uci.data.rule, rule({ action: 'block', domain: 'example.com',
        source_ip_cidr: ['192.168.1.5'] }));
    });

    for (const [name, [config, reason]] of Object.entries(blocked))
      await check(`${version} ${name}: blocked`, async () => {
        const { env, modal, notice } = await openNotice(version, config);
        assert.equal(hasButton(notice, 'Convert…'), false, 'the conversion must not be offered');
        assert.match(notice.textContent, /cannot be converted/);
        assert.match(notice.textContent, reason);
        await modal.save();
        assert.deepEqual(env.uci.data, config, 'a plain save changed UCI');
      });

    // Downloaded lists: shown, kept, nothing to click.
    await check(`${version} remote lists`, async () => {
      const config = { rule: rule({ action: 'block', remote_domain_lists: ['https://example.com/d.srs'],
        remote_subnet_lists: ['https://example.com/s.srs'] }) };
      const { env, modal, notice } = await openNotice(version, config);
      assert.match(notice.textContent, /remote_domain_lists = https:\/\/example\.com\/d\.srs — downloaded/);
      assert.match(notice.textContent, /remote_subnet_lists = https:\/\/example\.com\/s\.srs — downloaded/);
      assert.match(notice.textContent, /cannot be converted and stay as they are/);
      assert.equal(buttons(notice).length, 0);
      await modal.save();
      assert.deepEqual(env.uci.data, config);
    });

    // Unsupported podkop matchers: the validator refuses the rule and says
    // to remove them here; Remove… asks first and removes only them.
    await check(`${version} unsupported matchers`, async () => {
      const config = { rule: rule({ action: 'block', domain: 'example.com', local_domain_lists: ['/etc/list.lst'],
        subnet_text: '10.0.0.0/8' }) };
      const refused = backend.validate(config);
      assert.equal(refused.ok, false);
      assert.match(refused.message, /Remove it in the rule editor \(Legacy settings\)/);

      let { env, modal, notice } = await openNotice(version, config);
      assert.equal(modal.option('_legacy_conditions').title, 'Legacy settings');
      assert.match(notice.textContent, /local_domain_lists = \/etc\/list\.lst — no longer supported/);
      assert.match(notice.textContent, /subnet_text = 10\.0\.0\.0\/8 — no longer supported/);
      button(notice, 'Remove…').attrs.click();
      assert.match(notice.textContent, /Remove (local_domain_lists, subnet_text|subnet_text, local_domain_lists) from this rule\?/);
      button(notice, 'Cancel').attrs.click();
      await modal.save();
      assert.deepEqual(env.uci.data, config, 'a cancelled removal changed UCI');

      ({ env, modal, notice } = await openNotice(version, config));
      button(notice, 'Remove…').attrs.click();
      button(notice, 'Remove').attrs.click();
      assert.match(notice.textContent, /removed/);
      await modal.save();
      const expected = JSON.parse(JSON.stringify(config));
      delete expected.rule.local_domain_lists;
      delete expected.rule.subnet_text;
      assert.deepEqual(env.uci.data, expected, 'only the unsupported options may go');
      const verdict = backend.validate(env.uci.data);
      assert.equal(verdict.ok, true, verdict.message);
    });

    // A read-only role: that legacy settings exist, no values, no actions.
    await check(`${version} read-only`, async () => {
      const config = { rule: rule({ action: 'block', domain: ['exact.example'],
        remote_domain_lists: ['https://user:secret@example.com/d.srs'], local_domain_lists: ['/etc/list.lst'] }) };
      const { notice } = await openNotice(version, config, { readonly: true });
      assert.match(notice.textContent, /legacy form/);
      assert.equal(buttons(notice).length, 0);
      for (const value of ['exact.example', 'secret', 'example.com', '/etc/list.lst', 'remote_domain_lists'])
        assert.equal(notice.textContent.includes(value), false, `the read-only notice shows ${value}`);
    });

    // Rules in the current form have no notice.
    await check(`${version} current form`, async () => {
      const config = { rule: rule({ action: 'connection', ...routed, domain: 'example.com\nkeyword:video',
        ip_cidr: '10.0.0.0/8', ports: ['443'], source_ip_cidr: ['192.168.1.2'], fully_routed_ips: ['192.168.1.3'],
        selector_proxy_links: ['socks5://10.0.0.1:1080'] }), if1: iface('if1', { name: 'wg0' }) };
      const env = createEnvironment({ version, config });
      const modal = await env.openRule('rule');
      assert.equal(modal.active('_legacy_conditions'), false);
    });
  }

  if (failures.length) {
    console.error(failures.map((failure) => `FAIL: ${failure}`).join('\n'));
    process.exit(1);
  }
  console.log('LuCI shows legacy rule settings and converts them without changing the generated config');
})();
NODE
