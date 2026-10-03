import { describe, expect, it, vi } from 'vitest';

import { replaceChildrenKeepingFocus } from '../replaceChildrenKeepingFocus';

// A minimal DOM: enough for focus lookup by tag, attributes and text.
class FakeElement {
  id = '';
  children: FakeElement[] = [];
  focus = vi.fn();

  constructor(
    public tagName: string,
    public text = '',
    private attrs: Record<string, string> = {},
  ) {}

  get textContent(): string {
    return this.text + this.children.map((child) => child.textContent).join('');
  }

  getAttribute(name: string) {
    return this.attrs[name] ?? null;
  }

  descendants(): FakeElement[] {
    return this.children.flatMap((child) => [child, ...child.descendants()]);
  }

  contains(node: unknown) {
    return node === this || this.descendants().includes(node as FakeElement);
  }

  querySelectorAll() {
    return this.descendants().filter((element) =>
      ['BUTTON', 'A', 'INPUT', 'SUMMARY'].includes(element.tagName),
    );
  }

  replaceChildren(...nodes: FakeElement[]) {
    this.children = nodes;
  }
}

function card(...buttons: string[]) {
  const node = new FakeElement('SECTION', 'Routing 4.2 MB/s');
  node.children = buttons.map((label) => new FakeElement('BUTTON', label));
  return node;
}

function mount(...nodes: FakeElement[]) {
  const doc: { activeElement: unknown } = { activeElement: null };
  const container = new FakeElement('DIV') as FakeElement & {
    ownerDocument: typeof doc;
  };
  container.ownerDocument = doc;
  container.replaceChildren(...nodes);
  return { container, doc };
}

function replace(container: FakeElement, ...nodes: FakeElement[]) {
  replaceChildrenKeepingFocus(
    container as unknown as Element,
    ...(nodes as unknown as Node[]),
  );
}

describe('replaceChildrenKeepingFocus', () => {
  it('moves focus to the same control after a refresh', () => {
    const { container, doc } = mount(card('Monitoring', 'All events'));
    doc.activeElement = container.children[0].children[1];

    const next = card('Monitoring', 'All events');
    replace(container, next);

    expect(container.children).toEqual([next]);
    expect(next.children[1].focus).toHaveBeenCalledWith({
      preventScroll: true,
    });
    expect(next.children[0].focus).not.toHaveBeenCalled();
  });

  it('falls back to the same position when only the label changed', () => {
    const { container, doc } = mount(card('Start', 'Restart'));
    doc.activeElement = container.children[0].children[0];

    const next = card('Starting…', 'Restart');
    replace(container, next);

    expect(next.children[0].focus).toHaveBeenCalled();
  });

  it('leaves focus alone when it is outside the container', () => {
    const { container, doc } = mount(card('Monitoring'));
    doc.activeElement = new FakeElement('BUTTON', 'Monitoring');

    const next = card('Monitoring');
    replace(container, next);

    expect(container.children).toEqual([next]);
    expect(next.children[0].focus).not.toHaveBeenCalled();
  });
});
