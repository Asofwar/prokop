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

function find(node: unknown, id: string): FakeNode | undefined {
  if (!node || typeof node !== 'object') return undefined;
  const fake = node as FakeNode;
  if (fake.attrs.id === id) return fake;
  for (const child of fake.children || []) {
    const found = find(child, id);
    if (found) return found;
  }
  return undefined;
}

import { render as renderOverview } from '../render';
import { render as renderAutotune } from '../../autotune/render';
import { render as renderHistory } from '../../history/render';

// These blocks hold buttons and links and are rebuilt on every poll or
// traffic tick; as live regions they would be re-announced each time.
describe('refreshed blocks are not live regions', () => {
  it.each([
    ['dashboard-overview', renderOverview],
    ['autotune-state', renderAutotune],
    ['history-state', renderHistory],
  ])('%s has no role=status', (id, render) => {
    const block = find(render(), id);

    expect(block).toBeDefined();
    expect(block?.attrs.role).toBeUndefined();
    expect(block?.attrs['aria-live']).toBeUndefined();
  });
});
