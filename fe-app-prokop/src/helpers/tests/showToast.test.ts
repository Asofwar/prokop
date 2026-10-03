import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { showToast } from '../showToast';

class FakeElement {
  className = '';
  textContent = '';
  attributes: Record<string, string> = {};
  children: FakeElement[] = [];
  removed = false;
  classList = { add: vi.fn(), remove: vi.fn() };
  setAttribute(name: string, value: string) {
    this.attributes[name] = value;
  }
  appendChild(child: FakeElement) {
    this.children.push(child);
  }
  remove() {
    this.removed = true;
  }
}

const g = globalThis as unknown as Record<string, unknown>;
let container: FakeElement | null;

beforeEach(() => {
  vi.useFakeTimers();
  container = null;
  g.document = {
    querySelector: () => container,
    createElement: () => new FakeElement(),
    body: {
      appendChild: (element: FakeElement) => {
        container = element;
      },
    },
  };
});

afterEach(() => {
  vi.useRealTimers();
  delete g.document;
});

describe('showToast', () => {
  it('announces toasts through a polite live region', () => {
    showToast('Saved', 'success');

    expect(container?.attributes.role).toBe('status');
    expect(container?.attributes['aria-live']).toBe('polite');
    expect(container?.children[0].attributes.role).toBeUndefined();
  });

  it('marks errors as alerts and keeps them for 8 s', () => {
    showToast('Failed', 'error');
    const toast = container!.children[0];

    expect(toast.attributes.role).toBe('alert');
    vi.advanceTimersByTime(7900);
    expect(toast.classList.remove).not.toHaveBeenCalled();
    vi.advanceTimersByTime(100 + 300);
    expect(toast.removed).toBe(true);
  });

  it('keeps the short default for other toasts', () => {
    showToast('Saved', 'success');
    const toast = container!.children[0];

    vi.advanceTimersByTime(3300);
    expect(toast.removed).toBe(true);
  });
});
