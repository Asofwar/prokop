import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import {
  SING_BOX_MASKED_KEYS,
  UCI_SAFE_OPTIONS,
  UCI_SAFE_SECTION_OPTIONS,
  UCI_URL_OPTIONS,
  formatMaskedSingBoxConfig,
  maskGlobalCheckText,
} from '../helpers/maskDiagnostics';

// The fixtures of tests/readonly_secret_masking.sh: every sensitive value
// carries a SECRET_MARKER_* substring (UC-002, UC-006).
const fixture = (name) =>
  readFileSync(
    new URL(
      `../../../../../../tests/fixtures/readonly_secrets/${name}`,
      import.meta.url,
    ),
    'utf8',
  );
const statusUc = readFileSync(
  new URL(
    '../../../../../../prokop/files/usr/lib/diagnostics/status.uc',
    import.meta.url,
  ),
  'utf8',
);

const markers = (text) => text.match(/SECRET_MARKER_\d+/g) ?? [];

function ucodeKeys(block) {
  return [...block.matchAll(/([a-z0-9_]+): true/g)]
    .map((match) => match[1])
    .sort();
}

function ucodeTable(name) {
  const match = statusUc.match(
    new RegExp(`let ${name} = \\{([\\s\\S]*?)\\n\\};`),
  );
  expect(match, name).not.toBeNull();
  return match[1];
}

describe('diagnostic masking of the secret fixtures', () => {
  it('masks every secret of the Prokop, WAN and dnsmasq UCI blocks of a global check', () => {
    const wanBlocks = [
      'static',
      'pppoe',
      'l2tp',
      'pptp',
      '3g',
      'qmi',
      'wireguard',
    ]
      .map((proto) => fixture('network').replaceAll('@WAN_PROTO@', proto))
      .join('\n');
    const raw = [
      '📡 Global check run!',
      '📄 Prokop config',
      fixture('prokop'),
      '━━━━━━━━━━━━━━━━━━━━━━━━━━━',
      '📄 WAN config',
      wanBlocks,
      'config dnsmasq',
      "\tlist server '127.0.0.42'",
      "\toption noresolv '1'",
      '🥸 FakeIP status',
    ].join('\n');
    expect(markers(raw).length).toBeGreaterThan(60);

    const masked = maskGlobalCheckText(raw);

    expect(markers(masked)).toEqual([]);
    expect(masked.split('\n')).toHaveLength(raw.split('\n').length);
    expect(masked).toContain('📡 Global check run!');
    expect(masked).toContain("option yacd_secret_key 'MASKED'");
    expect(masked).toContain("option enabled '1'");
    expect(masked).toContain("option name 'awg1'");
    expect(masked).toContain(
      "list rule_set 'https://MASKED@rules.example/rules.srs?MASKED'",
    );
    expect(masked).toContain("option proto 'l2tp'");
    expect(masked).toContain("option password 'MASKED'");
    expect(masked).toContain("list server '127.0.0.42'");
  });

  it('masks every secret of the sing-box config and keeps its structure', () => {
    const raw = fixture('sing-box.json');
    expect(markers(raw).length).toBeGreaterThan(40);

    const masked = formatMaskedSingBoxConfig(raw);

    expect(markers(masked)).toEqual([]);
    expect(masked).toContain('"tag": "main-out"');
    expect(masked).toContain('"type": "vless"');
    expect(masked).toContain(
      '"url": "https://MASKED@rules.example/r.srs?MASKED"',
    );
  });

  it('drops inline comments, schemeless userinfo and the raw validator message', () => {
    const raw = [
      "config settings 'settings'",
      "\toption enabled '1' # SECRET_MARKER_180",
      "\tlist rule_set '//SECRET_MARKER_182@rules.example/x.srs'",
      "\tlist rule_set 'https:/SECRET_MARKER_183@rules.example/x.srs'",
      "\tlist rule_set 'https://cdn.example/gh/user/repo@main/rules.srs'",
      '━━━━━━━━━━━━━━━━━━━━━━━━━━━',
      '🧪 Prokop configuration validation',
      "❌ Invalid main DNS server 'SECRET_MARKER_189'",
      'SECRET_MARKER_190',
      '━━━━━━━━━━━━━━━━━━━━━━━━━━━',
    ].join('\n');

    const masked = maskGlobalCheckText(raw);

    expect(markers(masked)).toEqual([]);
    expect(masked).toContain("\toption enabled '1'\n");
    expect(masked).toContain(
      "list rule_set 'https://cdn.example/gh/user/repo@main/rules.srs'",
    );
    expect(masked).toContain(
      '🧪 Prokop configuration validation\n❌ Prokop configuration validation failed\n━',
    );
  });

  it('uses the same tables as the backend masking in status.uc', () => {
    expect([...SING_BOX_MASKED_KEYS].sort()).toEqual(
      ucodeKeys(ucodeTable('masked_sing_box_keys')),
    );
    expect([...UCI_SAFE_OPTIONS].sort()).toEqual(
      ucodeKeys(ucodeTable('uci_safe_options')),
    );
    expect([...UCI_URL_OPTIONS].sort()).toEqual(
      ucodeKeys(ucodeTable('uci_url_options')),
    );
    const sections = ucodeTable('uci_safe_section_options');
    expect(Object.keys(UCI_SAFE_SECTION_OPTIONS).sort()).toEqual(
      [...sections.matchAll(/^ {4}([a-z0-9_]+): \{/gm)]
        .map((match) => match[1])
        .sort(),
    );
    for (const [type, options] of Object.entries(UCI_SAFE_SECTION_OPTIONS)) {
      const block = sections.match(new RegExp(`${type}: \\{([\\s\\S]*?)\\}`));
      expect([...options].sort()).toEqual(ucodeKeys(block[1]));
    }
  });
});
