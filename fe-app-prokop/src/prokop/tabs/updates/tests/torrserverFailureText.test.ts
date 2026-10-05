import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  componentActionFailureText,
  componentActionSuccessIsPartial,
  componentActionSuccessText,
} from '../componentActionToast';

const g = globalThis as unknown as { _: (key: string) => string };
const ru: Record<string, string> = {
  'Not enough free space for TorrServer: %s KiB free, %s KiB needed':
    'Недостаточно места для TorrServer: свободно %s КиБ, нужно %s КиБ',
  'TorrServer %s did not start; the previous version %s runs again':
    'TorrServer %s не запустился; снова работает прежняя версия %s',
  'Failed to download TorrServer': 'Не удалось скачать TorrServer',
};

describe('componentActionFailureText', () => {
  const original = g._;

  beforeEach(() => {
    g._ = (key: string) => ru[key] ?? key;
  });

  afterEach(() => {
    g._ = original;
  });

  it('translates the TorrServer failures with their values', () => {
    expect(componentActionFailureText('Failed to download TorrServer')).toBe(
      'Не удалось скачать TorrServer',
    );
    expect(
      componentActionFailureText(
        "Not enough free space on the router's storage to install TorrServer: 1024 KiB available where 40000 KiB is needed",
      ),
    ).toBe(
      'Недостаточно места для TorrServer: свободно 1024 КиБ, нужно 40000 КиБ',
    );
    expect(
      componentActionFailureText(
        'TorrServer MatriX.145.3 did not start; the previous version MatriX.145.2 runs again',
      ),
    ).toBe(
      'TorrServer MatriX.145.3 не запустился; снова работает прежняя версия MatriX.145.2',
    );
  });

  it('translates every TorrServer and TorrServer Direct failure (TS-6, TS-11)', () => {
    for (const message of [
      'TorrServer service is not available in this Prokop build',
      'Failed to read TorrServer paths',
      'Failed to create /opt/torrserver',
      "Failed to stage TorrServer on the router's storage",
      'Failed to keep the installed TorrServer aside for the update; it runs on unchanged',
      'Failed to install TorrServer; the previous version was restored',
      'Failed to install TorrServer; the previous version could not be restored',
      'Failed to install TorrServer',
      'Failed to remove TorrServer',
      'TorrServer MatriX.140 did not start',
      'TorrServer Direct service is not available',
      'This firmware does not provide kmod-nft-socket required for TorrServer Direct',
      'TorrServer is not running',
      'TorrServer does not have a dedicated cgroup',
      'Failed to save TorrServer Direct settings',
      'Failed to apply TorrServer Direct settings',
    ]) {
      g._ = (key: string) => `[RU]${key}`;
      expect(componentActionFailureText(message)).toMatch(/^\[RU\]/);
    }
    g._ = (key: string) => key;
    expect(
      componentActionFailureText('TorrServer MatriX.140 did not start'),
    ).toBe('TorrServer MatriX.140 did not start');
  });

  it('leaves other messages unchanged', () => {
    for (const message of [
      'Failed to install ByeDPI package',
      'Failed to create a backup of the configuration',
    ]) {
      expect(componentActionFailureText(message)).toBe(message);
    }
  });
});

describe('componentActionSuccessText', () => {
  it('warns when a fresh TorrServer did not take its settings (TS-11)', () => {
    const result = {
      component: 'torrserver' as const,
      action: 'install' as const,
      status: 'latest' as const,
    };
    expect(
      componentActionSuccessIsPartial({ ...result, settings_applied: 0 }),
    ).toBe(true);
    expect(
      componentActionSuccessText({ ...result, settings_applied: 0 }),
    ).toMatch(/recommended settings were not applied/);
    expect(
      componentActionSuccessIsPartial({ ...result, settings_applied: 1 }),
    ).toBe(false);
    expect(componentActionSuccessIsPartial(result)).toBe(false);
    expect(componentActionSuccessText(result)).toBe(
      '%s has been installed'.replace('%s', 'TorrServer'),
    );
  });
});
