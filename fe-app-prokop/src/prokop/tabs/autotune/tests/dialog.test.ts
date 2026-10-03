import { describe, expect, it, vi } from 'vitest';

interface FakeNode {
  tag: string;
  attrs: Record<string, unknown>;
  children: unknown[];
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
});

import { field, modalActions } from '../dialog';

function control(tagName: string) {
  const attributes: Record<string, string> = {};
  return {
    tagName,
    id: '',
    attributes,
    setAttribute: (name: string, value: string) => (attributes[name] = value),
  };
}

describe('autotune dialog parts', () => {
  it('points each label at its form control (UC-142)', () => {
    const input = control('INPUT');
    const select = control('SELECT');
    const [inputLabel] = field(
      'Check every',
      input as never,
    ) as unknown as FakeNode[];
    const [selectLabel] = field(
      'Kind',
      select as never,
    ) as unknown as FakeNode[];

    expect(input.id).not.toBe('');
    expect(inputLabel.attrs.for).toBe(input.id);
    expect(selectLabel.attrs.for).toBe(select.id);
    expect(select.id).not.toBe(input.id);
  });

  it('names a control group by its label (UC-142)', () => {
    const picker = control('DIV');
    const [label] = field(
      'Domains of the list',
      picker as never,
    ) as unknown as FakeNode[];

    expect(picker.attributes.role).toBe('group');
    expect(picker.attributes['aria-labelledby']).toBe(label.attrs.id);
  });

  it('puts Cancel first inside .right so Escape cancels (UC-134)', () => {
    const hideModal = vi.fn();
    g.ui = { hideModal };
    const actions = modalActions(vi.fn(), 'Save') as unknown as FakeNode;
    const [first] = actions.children as FakeNode[];

    expect(String(actions.attrs.class).split(' ')).toContain('right');
    expect(first.tag).toBe('button');
    expect(first.children).toEqual(['Cancel']);
    (first.attrs.click as () => void)();
    expect(hideModal).toHaveBeenCalledOnce();
  });
});
