import { describe, expect, it, vi } from 'vitest';

vi.mock('../systemInfo.service', () => ({ ensureSystemInfo: vi.fn() }));

import {
  isStaleInterface,
  staleInterfaceMessage,
} from '../staleInterface.service';

describe('isStaleInterface', () => {
  it('reports two different release versions', () => {
    expect(isStaleInterface('2.13.0', '2.14.0')).toBe(true);
    expect(isStaleInterface('2.14.0', '2.14.0-1')).toBe(true);
  });

  it('does not report the same version', () => {
    expect(isStaleInterface('2.14.0', '2.14.0')).toBe(false);
    expect(isStaleInterface(' 2.14.0', '2.14.0\n')).toBe(false);
  });

  it('says nothing about a development build or an unknown version', () => {
    expect(isStaleInterface('__COMPILED_VERSION_VARIABLE__', '2.14.0')).toBe(
      false,
    );
    expect(isStaleInterface('2.14.0', 'not installed')).toBe(false);
    expect(isStaleInterface('2.14.0', '')).toBe(false);
    expect(isStaleInterface('2.14.0', 'unknown')).toBe(false);
    expect(isStaleInterface('dev', '2.14.0')).toBe(false);
  });
});

describe('staleInterfaceMessage', () => {
  it('names the loaded and the installed version', () => {
    const message = staleInterfaceMessage('2.13.0', '2.14.0');
    expect(message).toContain('2.13.0');
    expect(message).toContain('2.14.0');
    expect(message.indexOf('2.13.0')).toBeLessThan(message.indexOf('2.14.0'));
  });
});
