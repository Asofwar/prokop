import { readFileSync } from 'fs';
import { dirname, resolve } from 'path';
import { fileURLToPath } from 'url';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { componentActionFailureMessage } from '../componentActionToast';

// The Russian catalog as LuCI loads it: a text without an entry shows up.
function russianCatalog() {
  const po = readFileSync(
    resolve(
      dirname(fileURLToPath(import.meta.url)),
      '../../../../../../luci-app-prokop/po/ru/prokop.po',
    ),
    'utf8',
  );
  const unquote = (text) => JSON.parse(`"${text}"`);
  const catalog = {};
  const entry = /^msgid "(.*)"\nmsgstr "(.*)"$/gm;
  for (const match of po.matchAll(entry)) {
    if (match[1] && match[2]) {
      catalog[unquote(match[1])] = unquote(match[2]);
    }
  }
  return catalog;
}

const g = globalThis;

describe('componentActionFailureMessage (FE-15)', () => {
  const original = g._;
  const ru = russianCatalog();

  beforeEach(() => {
    g._ = (key) => ru[key] ?? `UNTRANSLATED(${key})`;
  });

  afterEach(() => {
    g._ = original;
  });

  const failures = [
    ['Failed to update package lists', { component: 'zapret' }],
    ['Failed to download ByeDPI package', { component: 'byedpi' }],
    [
      'Failed to download the sing-box package; the current sing-box was kept: the router ran out of storage space',
      { component: 'sing_box' },
    ],
    [
      "Not enough free space on the router's storage to install stable sing-box: 100 KiB available where 9000 KiB is needed",
      { component: 'sing_box' },
    ],
    [
      'Release package checksum mismatch for prokop_2.25.4.ipk',
      { component: 'prokop' },
    ],
    [
      'Stable sing-box package installation failed; previous sing-box variant was restored',
      { component: 'sing_box' },
    ],
    [
      'tiny sing-box was installed but Prokop did not start cleanly and previous sing-box variant could not be restored',
      { component: 'sing_box' },
    ],
    ['Failed to resolve Prokop release', { component: 'prokop' }],
    ['sing-box-extended is not installed', { component: 'sing_box' }],
    [
      'TorrServer Direct service is not available',
      { component: 'torrserver_direct' },
    ],
    [
      'Prokop was not stopped: another sing-box process makes the ownership of its runtime ambiguous; the current sing-box variant was kept',
      { component: 'sing_box' },
    ],
    [
      'The configured mirror uses http://; binaries and scripts are installed only from an https:// mirror',
      { component: 'zapret_manager' },
    ],
    [
      'Failed to save TorrServer Direct settings',
      { component: 'torrserver_direct' },
    ],
    ['Something nobody mapped', undefined],
  ];

  it.each(failures)('says "%s" in Russian', (message, result) => {
    const text = componentActionFailureMessage({ error: message }, result);
    expect(text).not.toContain('UNTRANSLATED');
    expect(text).not.toContain(message);
  });

  it('keeps the values a user needs', () => {
    expect(
      componentActionFailureMessage(
        {
          error:
            'Installed Prokop 2.25.3 is not published in this Prokop channel, so it cannot be staged for rollback; automatic upgrade refused. Run the one-line installer to switch this router to this fork: wget -qO- https://asofwar.github.io/prokop/install.sh | sh',
        },
        { component: 'prokop' },
      ),
    ).toContain('2.25.3');
    expect(
      componentActionFailureMessage(
        {
          error:
            'Installed Prokop 2.25.3 is not published in this Prokop channel, so it cannot be staged for rollback; automatic upgrade refused. Run the one-line installer to switch this router to this fork: wget -qO- https://asofwar.github.io/prokop/install.sh | sh',
        },
        { component: 'prokop' },
      ),
    ).toContain('wget -qO- https://asofwar.github.io/prokop/install.sh | sh');
  });

  it('prefers the translated reason and still translates TorrServer', () => {
    expect(
      componentActionFailureMessage(
        {
          reason: 'busy',
          error: 'Another component action is already running',
        },
        { component: 'zapret' },
      ),
    ).toBe(
      ru[
        'Another action of this kind is already running. Try again when it finishes.'
      ],
    );
    expect(
      componentActionFailureMessage(
        { error: 'Failed to download TorrServer' },
        {
          component: 'torrserver',
        },
      ),
    ).toBe(ru['Failed to download TorrServer']);
  });
});
