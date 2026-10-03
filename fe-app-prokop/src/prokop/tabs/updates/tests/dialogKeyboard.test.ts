import { beforeEach, describe, expect, it, vi } from 'vitest';

interface FakeNode {
  tag: string;
  attrs: Record<string, unknown>;
  children: unknown[];
  focus: ReturnType<typeof vi.fn>;
  textContent?: string;
  value?: string;
  options?: unknown[];
}

function text(node: unknown): string {
  if (typeof node === 'string') return node;
  if (!node || typeof node !== 'object') return '';
  return ((node as FakeNode).children || []).map(text).join('');
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
) => {
  const node: FakeNode & Record<string, unknown> = {
    tag,
    attrs,
    children: (Array.isArray(children) ? children : [children]).filter(
      (child) => child !== undefined,
    ),
    focus: vi.fn(),
    appendChild(child: unknown) {
      node.children.push(child);
    },
    replaceChildren(...next: unknown[]) {
      node.children = next;
    },
    addEventListener() {},
  };
  if (tag === 'select') {
    Object.defineProperty(node, 'options', { get: () => node.children });
    Object.defineProperty(node, 'value', {
      get: () => (node.children[0] as FakeNode | undefined)?.attrs.value,
    });
  }
  return node;
};

const shell = vi.hoisted(() => ({ execute: vi.fn() }));
vi.mock('../../../../helpers/executeShellCommand', () => ({
  executeShellCommand: shell.execute,
}));
vi.mock('../../../../helpers', () => ({
  executeShellCommand: shell.execute,
  insertIf: (condition: boolean, items: unknown[]) => (condition ? items : []),
}));

import { showReleaseSelector } from '../releaseSelector';
import { confirmRemoval } from '../fullUninstall';

// LuCI's cancelModal: Escape clicks the first '.right > button'.
function escapeTarget(content: unknown): FakeNode | undefined {
  const [right] = find(content, (n) =>
    String(n.attrs.class ?? '')
      .split(' ')
      .includes('right'),
  );
  return (right?.children as FakeNode[] | undefined)?.find(
    (child) => child?.tag === 'button',
  );
}

let modals: { title: string; content: FakeNode }[];

beforeEach(() => {
  modals = [];
  g.ui = {
    showModal: (title: string, content: FakeNode) => {
      modals.push({ title, content });
    },
    hideModal: vi.fn(),
  };
  shell.execute.mockReset();
});

describe('Full removal dialog', () => {
  it('focuses Cancel, and Escape cancels (UC-133, UC-134)', () => {
    confirmRemoval();
    const [modal] = modals;
    const cancel = escapeTarget(modal.content)!;

    expect(text(cancel)).toBe('Cancel');
    expect(cancel.focus).toHaveBeenCalledOnce();
  });
});

describe('Prokop version selector', () => {
  it('can be cancelled with Escape while versions load (UC-134)', () => {
    shell.execute.mockReturnValue(new Promise(() => undefined));
    void showReleaseSelector('1.0.0', vi.fn());

    const cancel = escapeTarget(modals[0].content)!;
    expect(text(cancel)).toBe('Cancel');
    (cancel.attrs.click as () => void)();
    expect((g.ui as { hideModal: () => void }).hideModal).toHaveBeenCalled();
  });

  it('keeps Close reachable by Escape after a load error (UC-134)', async () => {
    shell.execute.mockResolvedValue({ stdout: '{}', stderr: '', code: 1 });
    await showReleaseSelector('1.0.0', vi.fn());

    expect(text(escapeTarget(modals[0].content))).toBe('Close');
  });

  it('focuses Cancel in the version-change confirmation (UC-133)', async () => {
    shell.execute.mockResolvedValue({
      stdout: JSON.stringify({
        success: true,
        releases: [{ version: '2.0.0', channel: 'stable' }],
      }),
      stderr: '',
      code: 0,
    });
    await showReleaseSelector('1.0.0', vi.fn());
    const [install] = find(
      modals[0].content,
      (n) => n.tag === 'button' && text(n) === 'Install selected version',
    );
    (install.attrs.click as () => void)();

    const confirm = modals[1];
    expect(confirm.title).toBe('Confirm version change');
    const cancel = escapeTarget(confirm.content)!;
    expect(text(cancel)).toBe('Cancel');
    expect(cancel.focus).toHaveBeenCalledOnce();
  });
});
