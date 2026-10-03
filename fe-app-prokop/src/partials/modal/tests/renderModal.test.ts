import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('../../button/renderButton', () => ({
  renderButton: () => ({}),
}));
vi.mock('../../../helpers/copyToClipboard', () => ({
  copyToClipboard: vi.fn(),
}));
vi.mock('../../../helpers/downloadAsTxt', () => ({
  downloadAsTxt: vi.fn(),
}));

import { renderModal } from '../renderModal';

type Listener = () => void;

let visibilityListeners: Listener[] = [];
let fakeDocument: {
  hidden: boolean;
  body: object;
  addEventListener: (type: string, listener: Listener) => void;
  removeEventListener: (type: string, listener: Listener) => void;
};

beforeEach(() => {
  vi.useFakeTimers();
  visibilityListeners = [];
  fakeDocument = {
    hidden: false,
    body: {},
    addEventListener: (type, listener) => {
      if (type === 'visibilitychange') visibilityListeners.push(listener);
    },
    removeEventListener: (type, listener) => {
      if (type === 'visibilitychange') {
        visibilityListeners = visibilityListeners.filter(
          (item) => item !== listener,
        );
      }
    },
  };
  vi.stubGlobal('document', fakeDocument);
  vi.stubGlobal('E', () => ({ isConnected: true }));
  vi.stubGlobal('requestAnimationFrame', () => 0);
  vi.stubGlobal(
    'MutationObserver',
    class {
      observe() {}
      disconnect() {}
    },
  );
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe('renderModal live refresh', () => {
  it('refreshes at most once per refreshMs even when requests are slow', async () => {
    let resolveText: (text: string) => void = () => undefined;
    const getText = vi.fn(
      () =>
        new Promise<string>((resolve) => {
          resolveText = resolve;
        }),
    );

    renderModal('', 'logs', { getText, refreshMs: 2000 });
    expect(getText).toHaveBeenCalledTimes(1);

    // The first request takes longer than two ticks.
    await vi.advanceTimersByTimeAsync(4500);
    expect(getText).toHaveBeenCalledTimes(1);

    resolveText('a');
    await vi.advanceTimersByTimeAsync(0);
    // No queued refresh runs right after the slow one finishes.
    expect(getText).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(1500);
    expect(getText).toHaveBeenCalledTimes(2);
  });

  it('does not refresh while the page is hidden and catches up when shown', async () => {
    const getText = vi.fn(() => Promise.resolve('log'));

    renderModal('', 'logs', { getText, refreshMs: 2000 });
    await vi.advanceTimersByTimeAsync(0);
    expect(getText).toHaveBeenCalledTimes(1);

    fakeDocument.hidden = true;
    await vi.advanceTimersByTimeAsync(10000);
    expect(getText).toHaveBeenCalledTimes(1);

    fakeDocument.hidden = false;
    visibilityListeners.forEach((listener) => listener());
    await vi.advanceTimersByTimeAsync(0);
    expect(getText).toHaveBeenCalledTimes(2);
  });
});
