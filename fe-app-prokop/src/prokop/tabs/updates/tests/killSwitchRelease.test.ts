import { describe, expect, it } from 'vitest';

import { releaseLacksKillSwitch } from '../killSwitchRelease';

describe('release without the VPN kill-switch', () => {
  it('covers 1.0.31 and every older release', () => {
    expect(releaseLacksKillSwitch('1.0.31')).toBe(true);
    expect(releaseLacksKillSwitch('1.0.9')).toBe(true);
    expect(releaseLacksKillSwitch('0.9.40')).toBe(true);
  });

  it('does not cover releases that ship the kill-switch', () => {
    expect(releaseLacksKillSwitch('1.0.32')).toBe(false);
    expect(releaseLacksKillSwitch('1.1.0')).toBe(false);
    expect(releaseLacksKillSwitch('2.0.0')).toBe(false);
  });

  it('does not guess for a version it cannot read', () => {
    expect(releaseLacksKillSwitch('')).toBe(false);
    expect(releaseLacksKillSwitch('dev')).toBe(false);
  });
});
