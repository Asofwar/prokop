import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Prokop } from '../../../types';
import { createRouteNamesRefresher } from '../routeNamesRefresh';

function section(strategy: string): Prokop.ConfigSection[] {
  return [
    {
      '.name': 'main',
      '.type': 'section',
      action: 'proxy',
      dpi_strategy: strategy,
    } as Prokop.ConfigSection,
  ];
}

describe('createRouteNamesRefresher (UC-127)', () => {
  let hidden = false;

  beforeEach(() => {
    vi.useFakeTimers();
    hidden = false;
    vi.stubGlobal('document', {
      get hidden() {
        return hidden;
      },
    });
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('applies a changed configuration after the page was mounted', async () => {
    let router = section('old');
    const fetchSections = vi.fn(async () => router);
    const apply = vi.fn();
    const refresher = createRouteNamesRefresher({
      fetchSections,
      apply,
      intervalMs: 15000,
    });

    refresher.start();
    await vi.advanceTimersByTimeAsync(0);
    expect(apply).toHaveBeenLastCalledWith(section('old'));

    // Unchanged configuration is not applied again.
    await vi.advanceTimersByTimeAsync(15000);
    expect(fetchSections).toHaveBeenCalledTimes(2);
    expect(apply).toHaveBeenCalledTimes(1);

    // An autotune apply or a rule edit elsewhere.
    router = section('new');
    await vi.advanceTimersByTimeAsync(15000);
    expect(apply).toHaveBeenCalledTimes(2);
    expect(apply).toHaveBeenLastCalledWith(section('new'));

    refresher.stop();
  });

  it('does not poll while the page is hidden or after stop', async () => {
    const fetchSections = vi.fn(async () => section('old'));
    const refresher = createRouteNamesRefresher({
      fetchSections,
      apply: vi.fn(),
      intervalMs: 15000,
    });

    refresher.start();
    hidden = true;
    await vi.advanceTimersByTimeAsync(45000);
    expect(fetchSections).toHaveBeenCalledTimes(1);

    hidden = false;
    refresher.stop();
    await vi.advanceTimersByTimeAsync(45000);
    expect(fetchSections).toHaveBeenCalledTimes(1);
  });

  it('keeps the last names when a later refresh fails', async () => {
    const fetchSections = vi
      .fn<() => Promise<Prokop.ConfigSection[]>>()
      .mockResolvedValueOnce(section('old'))
      .mockRejectedValue(new Error('rpc failed'));
    const apply = vi.fn();
    const refresher = createRouteNamesRefresher({
      fetchSections,
      apply,
      intervalMs: 15000,
    });

    refresher.start();
    await vi.advanceTimersByTimeAsync(15000);

    expect(apply).toHaveBeenCalledTimes(1);
    expect(apply).toHaveBeenCalledWith(section('old'));
    refresher.stop();
  });

  it('settles the view with no names when the first load fails', async () => {
    const apply = vi.fn();
    const refresher = createRouteNamesRefresher({
      fetchSections: () => Promise.reject(new Error('rpc failed')),
      apply,
      intervalMs: 15000,
    });

    refresher.start();
    await vi.advanceTimersByTimeAsync(0);

    expect(apply).toHaveBeenCalledWith([]);
    refresher.stop();
  });
});
