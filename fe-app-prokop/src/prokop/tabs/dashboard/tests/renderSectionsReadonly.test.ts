import { describe, expect, it, vi } from 'vitest';

vi.mock('../../../../icons', () => ({
  renderLoaderCircleIcon24: () => 'svg',
  renderInfoIcon24: () => 'svg',
}));
vi.mock('../../../../helpers', () => ({
  svgEl: () => 'svg',
}));

interface FakeNode {
  tag: string;
  attrs: Record<string, unknown>;
  children: unknown[];
}

(globalThis as unknown as { E: unknown }).E = (
  tag: string,
  attrs: Record<string, unknown> = {},
  children: unknown = [],
): FakeNode => ({
  tag,
  attrs: attrs || {},
  children: Array.isArray(children) ? children : [children],
});

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

function text(node: unknown): string {
  if (typeof node === 'string') return node;
  if (!node || typeof node !== 'object') return '';
  return ((node as FakeNode).children || []).map(text).join(' ');
}

import { renderSections } from '../partials/renderSections';
import type { Prokop } from '../../../types';

function render(
  readonly: boolean,
  extra: Partial<Parameters<typeof renderSections>[0]> = {},
) {
  const handlers = {
    onTestLatency: vi.fn(),
    onChooseOutbound: vi.fn(),
    onUpdateSubscription: vi.fn(),
  };
  const section: Prokop.OutboundGroup = {
    withTagSelect: true,
    code: 'main-out',
    sectionName: 'main',
    displayName: 'Main',
    subscriptionSourceCount: 1,
    outbounds: [
      {
        code: 'a',
        displayName: 'A',
        latency: 40,
        type: 'vless',
        selected: true,
      },
      {
        code: 'b',
        displayName: 'B',
        latency: 90,
        type: 'vless',
        selected: false,
      },
    ],
  };
  const node = renderSections({
    loading: false,
    failed: false,
    section,
    ...handlers,
    onShowUrlTestInfo: vi.fn(),
    onShowPriorityInfo: vi.fn(),
    latencyFetching: false,
    subscriptionUpdating: false,
    isPriorityMembersExpanded: () => false,
    onPriorityMembersToggle: vi.fn(),
    readonly,
    ...extra,
  });
  return { node, handlers };
}

describe('dashboard sections in a read-only session', () => {
  it('renders no runtime controls', () => {
    const { node } = render(true);

    expect(find(node, (n) => n.tag === 'button')).toHaveLength(0);
    expect(text(node)).not.toContain('Test latency');
    expect(text(node)).not.toContain('Update subscriptions');
  });

  it('shows nodes but does not let them be selected', () => {
    const { node, handlers } = render(true);
    const tiles = find(node, (n) =>
      String(n.attrs.class || '').includes('outbound-grid__item '),
    );

    for (const tile of find(node, (n) => typeof n.attrs.click === 'function')) {
      (tile.attrs.click as () => void)();
    }
    expect(handlers.onChooseOutbound).not.toHaveBeenCalled();
    expect(
      tiles.some((tile) => String(tile.attrs.class).includes('--selectable')),
    ).toBe(false);
    expect(
      tiles.some((tile) => String(tile.attrs.class).includes('--disabled')),
    ).toBe(false);
  });

  it('keeps the controls for administrators', () => {
    const { node, handlers } = render(false);

    expect(text(node)).toContain('Test latency');
    expect(text(node)).toContain('Update subscriptions');
    const selectable = find(node, (n) =>
      String(n.attrs.class || '').includes('--selectable'),
    );
    (selectable[0].attrs.click as () => void)();
    expect(handlers.onChooseOutbound).toHaveBeenCalledWith(
      'main',
      'main-out',
      'b',
    );
  });

  it('lets the keyboard choose a node with Enter or Space', () => {
    const { node, handlers } = render(false);
    const tiles = find(node, (n) =>
      String(n.attrs.class || '').includes('outbound-grid__item '),
    );
    const selectable = tiles.find((tile) =>
      String(tile.attrs.class).includes('--selectable'),
    ) as FakeNode;
    const active = tiles.find((tile) =>
      String(tile.attrs.class).includes('--active'),
    ) as FakeNode;

    expect(selectable.attrs.role).toBe('button');
    expect(selectable.attrs.tabIndex).toBe(0);
    expect(selectable.attrs['aria-pressed']).toBe('false');
    expect(active.attrs['aria-pressed']).toBe('true');
    expect(active.attrs.tabIndex).toBeUndefined();

    const press = (key: string, target?: unknown) => {
      const event = { key, preventDefault: vi.fn() } as unknown as {
        key: string;
        target: unknown;
        currentTarget: unknown;
        preventDefault: () => void;
      };
      event.currentTarget = selectable;
      event.target = target ?? selectable;
      (selectable.attrs.keydown as (event: unknown) => void)(event);
      return event;
    };

    press('Tab');
    press('Enter', {});
    expect(handlers.onChooseOutbound).not.toHaveBeenCalled();

    expect(press('Enter').preventDefault).toHaveBeenCalled();
    press(' ');
    expect(handlers.onChooseOutbound).toHaveBeenCalledTimes(2);
    expect(handlers.onChooseOutbound).toHaveBeenCalledWith(
      'main',
      'main-out',
      'b',
    );
  });

  it('keeps read-only node cards out of the tab order', () => {
    const { node } = render(true);
    const tiles = find(node, (n) =>
      String(n.attrs.class || '').includes('outbound-grid__item '),
    );

    expect(tiles.length).toBeGreaterThan(0);
    for (const tile of tiles) {
      expect(tile.attrs.role).toBeUndefined();
      expect(tile.attrs.tabIndex).toBeUndefined();
    }
  });
});

describe('dashboard sections while Prokop is stopped', () => {
  it('says the service is stopped instead of showing the skeleton', () => {
    const { node } = render(false, {
      loading: true,
      stopped: true,
      stoppedActions: ['start-button' as unknown as HTMLElement],
    });

    expect(
      find(node, (n) => n.attrs.id === 'dashboard-sections-grid-skeleton'),
    ).toHaveLength(0);
    expect(text(node)).toContain(
      'Prokop service is stopped. Start the service to display nodes and groups.',
    );
    expect(text(node)).toContain('start-button');
  });

  it('hides stale node cards once the service stops', () => {
    const { node } = render(false, { stopped: true });

    expect(
      find(node, (n) =>
        String(n.attrs.class || '').includes('outbound-grid__item '),
      ),
    ).toHaveLength(0);
  });
});
