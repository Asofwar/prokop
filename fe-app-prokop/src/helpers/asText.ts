type TextPart = Node | string | number | boolean | null | undefined;

function isNode(value: unknown): value is Node {
  return typeof value === 'object' && value !== null && 'nodeType' in value;
}

/**
 * Children for LuCI E() that are always rendered as text.
 *
 * LuCI's dom.append assigns innerHTML when the children argument is a single
 * string; inside an array every string becomes a text node. Anything that is
 * not a literal (backend data, node names, sniffed hosts, translations with
 * substitutions) goes through here so it can never be parsed as HTML.
 * Nodes pass through unchanged; null and undefined render nothing.
 */
export function asText(value: TextPart | TextPart[]): (Node | string)[] {
  const parts = Array.isArray(value) ? value : [value];
  const children: (Node | string)[] = [];
  for (const part of parts) {
    if (part === null || part === undefined) continue;
    children.push(isNode(part) ? part : String(part));
  }
  return children;
}
