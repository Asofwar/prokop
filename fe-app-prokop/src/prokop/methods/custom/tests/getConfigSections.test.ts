import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  getReadonlyConfigSections: vi.fn(),
}));

vi.mock('../../shell', () => ({
  ProkopShellMethods: {
    getReadonlyConfigSections: mocks.getReadonlyConfigSections,
  },
}));

import { getConfigSections } from '../getConfigSections';
import type { Prokop } from '../../../types';

describe('getConfigSections ACL fallback', () => {
  beforeEach(() => {
    mocks.getReadonlyConfigSections.mockReset();
    vi.stubGlobal('uci', {
      load: vi.fn().mockResolvedValue(undefined),
      sections: vi
        .fn()
        .mockResolvedValue([
          { '.name': 'main', '.type': 'section', password: 'write-only' },
        ]),
    });
  });

  it('keeps full configuration for a user with UCI access', async () => {
    expect(await getConfigSections()).toMatchObject([
      { password: 'write-only' },
    ]);
    expect(mocks.getReadonlyConfigSections).not.toHaveBeenCalled();
  });

  it('uses sanitized sections when UCI read is denied', async () => {
    vi.mocked(uci.sections).mockRejectedValue(new Error('permission denied'));
    mocks.getReadonlyConfigSections.mockResolvedValue({
      success: true,
      data: [{ '.name': 'main', '.type': 'section', action: 'proxy' }],
    });
    expect(await getConfigSections()).toEqual([
      { '.name': 'main', '.type': 'section', action: 'proxy' },
    ]);
    expect(mocks.getReadonlyConfigSections).toHaveBeenCalledOnce();
  });
});

// LuCI's uci client: load() keeps the first copy until unload().
function createCachingUci(readRouter: () => Prokop.ConfigSection[]) {
  const state = {
    values: {} as Record<string, Prokop.ConfigSection[]>,
    changes: {} as Record<string, unknown>,
    creates: {} as Record<string, unknown>,
    deletes: {} as Record<string, unknown>,
    reorder: {} as Record<string, unknown>,
  };

  return {
    state,
    load: vi.fn(async (conf: string) => {
      if (!state.values[conf]) state.values[conf] = readRouter();
      return conf;
    }),
    unload: vi.fn((conf: string) => {
      delete state.values[conf];
    }),
    sections: vi.fn(async (conf: string) => state.values[conf] ?? []),
  };
}

describe('getConfigSections freshness (UC-127)', () => {
  it('returns the saved configuration on a later call', async () => {
    let router: Prokop.ConfigSection[] = [
      { '.name': 'main', '.type': 'section', label: 'Old' },
    ];
    vi.stubGlobal(
      'uci',
      createCachingUci(() => router),
    );

    expect(await getConfigSections()).toMatchObject([{ label: 'Old' }]);

    router = [{ '.name': 'main', '.type': 'section', label: 'New' }];

    expect(await getConfigSections()).toMatchObject([{ label: 'New' }]);
  });

  it('keeps the loaded copy while this page has unsaved edits', async () => {
    let router: Prokop.ConfigSection[] = [
      { '.name': 'main', '.type': 'section', label: 'Old' },
    ];
    const fakeUci = createCachingUci(() => router);
    vi.stubGlobal('uci', fakeUci);

    await getConfigSections();
    fakeUci.state.changes.prokop = { main: { label: 'Edited' } };
    router = [{ '.name': 'main', '.type': 'section', label: 'New' }];

    expect(await getConfigSections()).toMatchObject([{ label: 'Old' }]);
    expect(fakeUci.unload).toHaveBeenCalledTimes(1);
  });
});
