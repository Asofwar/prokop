import { describe, expect, it, vi } from 'vitest';
import { renderOnAttach } from '../renderOnAttach';

const flush = async () => {
  await Promise.resolve();
  await Promise.resolve();
};

describe('renderOnAttach', () => {
  it('fills a re-rendered container once it is attached', async () => {
    const root = {} as HTMLElement;
    let attach: () => void = () => undefined;
    const waitForAttach = vi.fn(
      () => new Promise<void>((resolve) => (attach = resolve)),
    );
    const renderComponents = vi.fn();

    renderOnAttach(root, {
      isMounted: () => true,
      waitForAttach,
      renderComponents,
    });

    expect(waitForAttach).toHaveBeenCalledWith(root);
    expect(renderComponents).not.toHaveBeenCalled();
    attach();
    await flush();
    expect(renderComponents).toHaveBeenCalledOnce();
  });

  it('leaves the first render to the page mount', () => {
    const waitForAttach = vi.fn(() => Promise.resolve());
    renderOnAttach({} as HTMLElement, {
      isMounted: () => false,
      waitForAttach,
      renderComponents: vi.fn(),
    });

    expect(waitForAttach).not.toHaveBeenCalled();
  });

  it('skips the render when the page was left before attaching', async () => {
    let mounted = true;
    const renderComponents = vi.fn();
    renderOnAttach({} as HTMLElement, {
      isMounted: () => mounted,
      waitForAttach: () => Promise.resolve(),
      renderComponents,
    });
    mounted = false;
    await flush();

    expect(renderComponents).not.toHaveBeenCalled();
  });
});
