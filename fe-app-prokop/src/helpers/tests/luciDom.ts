// A minimal model of LuCI's E()/dom.append (luci-base luci.js) for tests:
// a single string child is assigned to innerHTML, array items become text
// nodes. Tests use it to prove that untrusted text never reaches innerHTML.

export interface FakeLuciNode {
  nodeType: number;
  tag: string;
  attrs: Record<string, unknown>;
  children: FakeLuciNode[];
  text?: string;
  innerHTML?: string;
  appendChild(child: FakeLuciNode): FakeLuciNode;
  addEventListener(): void;
  setAttribute(name: string, value: string): void;
}

function node(tag: string, attrs: Record<string, unknown> = {}): FakeLuciNode {
  return {
    nodeType: 1,
    tag,
    attrs,
    children: [],
    appendChild(child) {
      this.children.push(child);
      return child;
    },
    addEventListener() {},
    setAttribute(name, value) {
      this.attrs[name] = value;
    },
  };
}

function textNode(value: string): FakeLuciNode {
  return { ...node('#text'), nodeType: 3, text: value };
}

function isElem(value: unknown): value is FakeLuciNode {
  return typeof value === 'object' && value !== null && 'nodeType' in value;
}

export function luciAppend(target: FakeLuciNode, children: unknown) {
  if (Array.isArray(children)) {
    for (const child of children) {
      if (isElem(child)) target.appendChild(child);
      else if (child !== null && child !== undefined)
        target.appendChild(textNode(`${child}`));
    }
  } else if (isElem(children)) {
    target.appendChild(children);
  } else if (children !== null && children !== undefined) {
    target.innerHTML = `${children}`;
  }
}

export function luciE(
  tag: string,
  attrs?: Record<string, unknown> | null,
  children?: unknown,
) {
  const element = node(tag, attrs ?? {});
  luciAppend(element, children);
  return element;
}

/** Every innerHTML assignment anywhere under the given roots. */
export function collectInnerHtml(...roots: unknown[]): string[] {
  const found: string[] = [];
  const walk = (value: unknown) => {
    if (Array.isArray(value)) return value.forEach(walk);
    if (!isElem(value)) return;
    if (value.innerHTML !== undefined) found.push(value.innerHTML);
    value.children.forEach(walk);
  };
  roots.forEach(walk);
  return found;
}

/** Concatenated text content under the given roots. */
export function collectText(...roots: unknown[]): string {
  let text = '';
  const walk = (value: unknown) => {
    if (Array.isArray(value)) return value.forEach(walk);
    if (!isElem(value)) return;
    if (value.text !== undefined) text += value.text;
    value.children.forEach(walk);
  };
  roots.forEach(walk);
  return text;
}
