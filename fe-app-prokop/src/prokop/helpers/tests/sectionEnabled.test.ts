import { describe, expect, it } from 'vitest';
import { isSectionEnabled } from '../sectionEnabled';

describe('isSectionEnabled', () => {
  it('reads the flag as the backend does', () => {
    for (const on of [undefined, null, '1', 'on', 'On', 'TRUE', 'yes', 'Yes'])
      expect(isSectionEnabled(on)).toBe(true);
    for (const off of ['0', 'off', 'OFF', 'false', 'no', '', '2'])
      expect(isSectionEnabled(off)).toBe(false);
  });
});
