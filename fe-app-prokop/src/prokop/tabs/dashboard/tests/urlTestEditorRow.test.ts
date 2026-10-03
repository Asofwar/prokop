import { describe, expect, it } from 'vitest';

interface FakeNode {
  tag: string;
  attrs: Record<string, unknown>;
  children: unknown[];
  id?: string;
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

import { renderUrlTestEditorRow } from '../urlTestEditorRow';

function control(id = ''): HTMLElement {
  return {
    tag: 'input',
    attrs: {},
    children: [],
    id,
  } as unknown as HTMLElement;
}

describe('URLTest editor rows', () => {
  it('associates each label with its control', () => {
    const first = control();
    const second = control();
    const rows = [
      renderUrlTestEditorRow('Interval', first),
      renderUrlTestEditorRow('Tolerance', second),
    ] as unknown as FakeNode[];

    expect(first.id).not.toBe('');
    expect(second.id).not.toBe(first.id);
    rows.forEach((row, index) => {
      const [label, field] = row.children as FakeNode[];
      expect(label.tag).toBe('label');
      expect(label.attrs.for).toBe(field.id);
      expect(field).toBe([first, second][index]);
    });
  });

  it('keeps an id the control already has', () => {
    const field = control('own-id');
    const row = renderUrlTestEditorRow('URL', field) as unknown as FakeNode;

    expect(field.id).toBe('own-id');
    expect((row.children[0] as FakeNode).attrs.for).toBe('own-id');
  });
});
