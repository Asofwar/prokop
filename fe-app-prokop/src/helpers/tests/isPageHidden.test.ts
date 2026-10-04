import { afterEach, describe, expect, it, vi } from 'vitest';

import { isPageHidden } from '../isPageHidden';

// FE-7: the periodic polls of a background tab skip their turn.
describe('isPageHidden', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('follows the visibility of the tab', () => {
    vi.stubGlobal('document', { hidden: true });
    expect(isPageHidden()).toBe(true);
    vi.stubGlobal('document', { hidden: false });
    expect(isPageHidden()).toBe(false);
  });

  it('is visible where there is no document', () => {
    expect(isPageHidden()).toBe(false);
  });
});
