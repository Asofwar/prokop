import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { componentActionFailureText } from '../componentActionToast';

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

  it('leaves other messages, TorrServer Direct included, unchanged', () => {
    for (const message of [
      'TorrServer is not running',
      'TorrServer Direct service is not available',
      'Failed to install ByeDPI package',
    ]) {
      expect(componentActionFailureText(message)).toBe(message);
    }
  });
});
