import { describe, expect, it, vi } from 'vitest';

vi.mock('../../methods', () => ({ ProkopShellMethods: {} }));
vi.mock('../../../icons', () => ({ renderSearchIcon24: () => 'svg' }));
vi.mock('../../../partials', () => ({ renderButton: () => 'button' }));

import {
  CONNECTIVITY_TARGETS_KEY,
  DIAGNOSTIC_LAST_RUN_KEY,
  LEGACY_FORKOP_STORAGE_KEYS,
  MONITORING_PREFERENCES_KEY,
  readStorageItem,
  writeStorageItem,
} from '../legacyStorage';
import { loadTargets } from '../../tabs/diagnostic/connectivityMatrix';
import {
  readLastRun,
  saveLastRun,
} from '../../tabs/diagnostic/partials/renderRunAction';

function memoryStorage(initial: Record<string, string> = {}) {
  const store = new Map(Object.entries(initial));
  return {
    store,
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => void store.set(key, value),
    removeItem: (key: string) => void store.delete(key),
  };
}

describe('browser preferences kept under Forkop names', () => {
  it('maps every Prokop key to its Forkop name', () => {
    expect(LEGACY_FORKOP_STORAGE_KEYS).toEqual({
      'prokop.monitoring.preferences': 'forkop.monitoring.preferences',
      'prokop.connectivity.targets': 'forkop.connectivity.targets',
      'prokop.diagnostic.lastRun': 'forkop.diagnostic.lastRun',
    });
    expect(MONITORING_PREFERENCES_KEY).toBe('prokop.monitoring.preferences');
    expect(CONNECTIVITY_TARGETS_KEY).toBe('prokop.connectivity.targets');
    expect(DIAGNOSTIC_LAST_RUN_KEY).toBe('prokop.diagnostic.lastRun');
  });

  it.each(Object.entries(LEGACY_FORKOP_STORAGE_KEYS))(
    'moves %s from %s once',
    (key, legacyKey) => {
      const storage = memoryStorage({ [legacyKey]: '{"kept":true}' });

      expect(readStorageItem(storage, key)).toBe('{"kept":true}');
      expect(storage.store.get(key)).toBe('{"kept":true}');
      expect(storage.store.has(legacyKey)).toBe(false);

      expect(readStorageItem(storage, key)).toBe('{"kept":true}');
    },
  );

  it('prefers the Prokop key and leaves unknown keys alone', () => {
    const storage = memoryStorage({
      'prokop.monitoring.preferences': '{"new":true}',
      'forkop.monitoring.preferences': '{"old":true}',
      'forkop.other': 'x',
    });

    expect(readStorageItem(storage, MONITORING_PREFERENCES_KEY)).toBe(
      '{"new":true}',
    );
    expect(readStorageItem(storage, 'prokop.other')).toBeNull();
    expect(storage.store.get('forkop.other')).toBe('x');
  });

  it('returns null when neither key exists', () => {
    const storage = memoryStorage();

    expect(readStorageItem(storage, CONNECTIVITY_TARGETS_KEY)).toBeNull();
    expect(storage.store.size).toBe(0);
  });

  it('keeps the Forkop key when the Prokop key cannot be written', () => {
    const storage = {
      ...memoryStorage({ 'forkop.diagnostic.lastRun': '42' }),
      setItem: () => {
        throw new Error('QuotaExceededError');
      },
    };

    expect(readStorageItem(storage, DIAGNOSTIC_LAST_RUN_KEY)).toBe('42');
    expect(storage.store.get('forkop.diagnostic.lastRun')).toBe('42');
  });

  it('drops the Forkop key when the Prokop key is written', () => {
    const storage = memoryStorage({
      'forkop.monitoring.preferences': '{"sortMode":"total"}',
    });

    writeStorageItem(
      storage,
      MONITORING_PREFERENCES_KEY,
      '{"sortMode":"upload"}',
    );

    expect(Object.fromEntries(storage.store)).toEqual({
      'prokop.monitoring.preferences': '{"sortMode":"upload"}',
    });
  });

  it('keeps connectivity targets saved by Forkop', () => {
    const targets = [{ host: 'a.example', type: 'TCP', port: '22' }];
    const storage = memoryStorage({
      'forkop.connectivity.targets': JSON.stringify(targets),
    });

    expect(loadTargets(storage)).toEqual(targets);
    expect(storage.store.has('forkop.connectivity.targets')).toBe(false);
    expect(
      JSON.parse(storage.store.get(CONNECTIVITY_TARGETS_KEY) || ''),
    ).toEqual(targets);
  });

  it('keeps the last diagnostic run recorded by Forkop', () => {
    const at = Date.UTC(2026, 8, 27);
    const storage = memoryStorage({ 'forkop.diagnostic.lastRun': String(at) });

    expect(readLastRun(storage)).toBe(at);
    expect(Object.fromEntries(storage.store)).toEqual({
      'prokop.diagnostic.lastRun': String(at),
    });

    saveLastRun(storage, at + 1);
    expect(readLastRun(storage)).toBe(at + 1);
  });
});
