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
  renderEmptyState,
  renderErrorState,
  renderLoadingState,
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

  it('announces loading with the default or a given label', () => {
    const node = renderLoadingState() as unknown as FakeNode;

    expect(node.attrs.role).toBe('status');
    expect(text(node)).toContain('Loading…');
    expect(text(renderLoadingState('Loading snapshots…'))).toContain(
      'Loading snapshots…',
    );
  });
});

describe('confirmAction', () => {
  let shown: { title: unknown; content: FakeNode } | null;

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

    // Titles go to LuCI as text children, never as an HTML string.
    expect(shown!.title).toEqual(['Stop Prokop?']);
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

  // LuCI's cancelModal: Escape clicks the first '.right > button'.
  function pressEscape(content: FakeNode) {
    const [right] = find(content, (n) =>
      String(n.attrs.class ?? '')
        .split(' ')
        .includes('right'),
    );
    const button = (right?.children as FakeNode[] | undefined)?.find(
      (child) => child?.tag === 'button',
    );
    (button?.attrs.click as (() => void) | undefined)?.();
  }

  it('cancels on Escape', async () => {
    const result = confirmAction({
      title: 't',
      message: 'm',
      confirmLabel: 'Go',
      danger: true,
    });
    pressEscape(shown!.content);

    await expect(result).resolves.toBe(false);
  });

  it('treats a dialog replaced by another one as cancel', async () => {
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
