import { beforeEach, describe, expect, it, vi } from 'vitest';

interface FakeNode {
  tag: string;
  attrs: Record<string, unknown>;
  children: unknown[];
  isConnected?: boolean;
  focus?: () => void;
}

function text(node: unknown): string {
  if (typeof node === 'string') return node;
  if (!node || typeof node !== 'object') return '';
  return ((node as FakeNode).children || []).map(text).join(' ');
}

function find(
  node: unknown,
  predicate: (node: FakeNode) => boolean,
): FakeNode[] {
  if (!node || typeof node !== 'object') return [];
  const fake = node as FakeNode;
  return [
    ...(predicate(fake) ? [fake] : []),
    ...(fake.children || []).flatMap((child) => find(child, predicate)),
  ];
}

const g = globalThis as unknown as Record<string, unknown>;
g.E = (
  tag: string,
  attrs: Record<string, unknown> = {},
  children: unknown = [],
) => ({
  tag,
  attrs,
  children: Array.isArray(children) ? children : [children],
  isConnected: true,
});

import { confirmAction } from '../confirmAction';
import {
  renderAsyncState,
  renderEmptyState,
  renderErrorState,
} from '../states';

describe('state blocks', () => {
  it('renders an empty state with its hint and action', () => {
    const onClick = vi.fn();
    const node = renderEmptyState('No snapshots yet', 'Create one', {
      label: 'Create snapshot',
      onClick,
    });

    expect(text(node)).toContain('No snapshots yet');
    expect(text(node)).toContain('Create one');
    const [button] = find(node, (n) => n.tag === 'button');
    (button.attrs.click as () => void)();
    expect(onClick).toHaveBeenCalledOnce();
  });

  it('renders an error with retry and technical details', () => {
    const retry = vi.fn();
    const node = renderErrorState('Could not load data', retry, 'exit 1');

    expect(find(node, (n) => n.tag === 'details')).toHaveLength(1);
    expect(text(node)).toContain('exit 1');
    const [button] = find(node, (n) => n.tag === 'button');
    (button.attrs.click as () => void)();
    expect(retry).toHaveBeenCalledOnce();
  });

  it('keeps showing the last data while refreshing', () => {
    const renderReady = vi.fn(() => 'ready-view' as unknown as Node);

    expect(
      renderAsyncState({ phase: 'loading', data: 'x' }, { renderReady }),
    ).toBe('ready-view');
    expect(
      text(renderAsyncState({ phase: 'loading' }, { renderReady })),
    ).toContain('Loading…');
  });

  it('names the timeout in seconds', () => {
    const node = renderAsyncState(
      { phase: 'timeout' },
      { renderReady: () => 'x' as unknown as Node, timeoutMs: 15000 },
    );

    expect(text(node)).toContain('The router did not respond in 15 s');
  });
});

describe('confirmAction', () => {
  let shown: { title: string; content: FakeNode } | null;

  beforeEach(() => {
    shown = null;
    g.ui = {
      showModal: (title: string, content: FakeNode) => {
        shown = { title, content };
      },
      hideModal: vi.fn(),
    };
    g.document = { body: {} };
    g.MutationObserver = undefined;
  });

  function button(label: string) {
    return find(
      shown!.content,
      (n) => n.tag === 'button' && text(n) === label,
    )[0];
  }

  it('resolves true only when the action is confirmed', async () => {
    const result = confirmAction({
      title: 'Stop Prokop?',
      message: 'Traffic will bypass Prokop.',
      consequences: ['Routing rules stop applying'],
      confirmLabel: 'Stop',
      danger: true,
    });

    expect(shown!.title).toBe('Stop Prokop?');
    expect(text(shown!.content)).toContain('Routing rules stop applying');
    expect(button('Stop').attrs.class).toContain('cbi-button-negative');
    (button('Stop').attrs.click as () => void)();

    await expect(result).resolves.toBe(true);
  });

  it('resolves false on cancel', async () => {
    const result = confirmAction({
      title: 't',
      message: 'm',
      confirmLabel: 'Go',
    });
    (button('Cancel').attrs.click as () => void)();

    await expect(result).resolves.toBe(false);
  });

  it('treats a modal closed from outside as cancel', async () => {
    let notify: () => void = () => undefined;
    g.MutationObserver = class {
      constructor(callback: () => void) {
        notify = callback;
      }
      observe() {}
      disconnect() {}
    };

    const result = confirmAction({
      title: 't',
      message: 'm',
      confirmLabel: 'Go',
    });
    shown!.content.isConnected = false;
    notify();

    await expect(result).resolves.toBe(false);
    expect(
      (g.ui as { hideModal: ReturnType<typeof vi.fn> }).hideModal,
    ).not.toHaveBeenCalled();
  });
});
