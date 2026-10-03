// Browser preferences the LuCI pages keep in localStorage.
export const MONITORING_PREFERENCES_KEY = 'prokop.monitoring.preferences';
export const CONNECTIVITY_TARGETS_KEY = 'prokop.connectivity.targets';
export const DIAGNOSTIC_LAST_RUN_KEY = 'prokop.diagnostic.lastRun';

// Before the project was renamed from Forkop to Prokop these preferences were
// kept under Forkop's names. A read falls back to the old key once, moves the
// value to the new key and removes the old one, so the preferences survive the
// switch from Forkop.
export const LEGACY_FORKOP_STORAGE_KEYS: Readonly<Record<string, string>> = {
  [MONITORING_PREFERENCES_KEY]: 'forkop.monitoring.preferences',
  [CONNECTIVITY_TARGETS_KEY]: 'forkop.connectivity.targets',
  [DIAGNOSTIC_LAST_RUN_KEY]: 'forkop.diagnostic.lastRun',
};

export type ReadableStorage = Pick<Storage, 'getItem'> &
  Partial<Pick<Storage, 'setItem' | 'removeItem'>>;
export type WritableStorage = Pick<Storage, 'setItem'> &
  Partial<Pick<Storage, 'removeItem'>>;

function legacyKeyFor(key: string): string | null {
  return Object.prototype.hasOwnProperty.call(LEGACY_FORKOP_STORAGE_KEYS, key)
    ? LEGACY_FORKOP_STORAGE_KEYS[key]
    : null;
}

export function readStorageItem(
  storage: ReadableStorage,
  key: string,
): string | null {
  const value = storage.getItem(key);
  const legacyKey = legacyKeyFor(key);
  if (value !== null || !legacyKey) return value;

  const legacyValue = storage.getItem(legacyKey);
  if (legacyValue === null) return null;
  if (storage.setItem) {
    try {
      storage.setItem(key, legacyValue);
      storage.removeItem?.(legacyKey);
    } catch (_error) {
      /* storage full or blocked: keep the old key, nothing is lost */
    }
  }
  return legacyValue;
}

export function writeStorageItem(
  storage: WritableStorage,
  key: string,
  value: string,
) {
  storage.setItem(key, value);
  const legacyKey = legacyKeyFor(key);
  if (legacyKey) storage.removeItem?.(legacyKey);
}
