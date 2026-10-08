export type OutboundGrouping = 'none' | 'country' | 'prefix';
interface NamedOutbound {
  displayName: string;
  country?: string;
}
export function groupOutbounds<T extends NamedOutbound>(
  nodes: T[],
  mode: OutboundGrouping,
): Map<string, T[]> {
  const groups = new Map<string, T[]>();
  for (const node of nodes) {
    const flag = node.displayName.match(/[\u{1F1E6}-\u{1F1FF}]{2}/u)?.[0];
    const flagCode = flag
      ? Array.from(flag)
          .map((letter) =>
            String.fromCharCode(letter.codePointAt(0)! - 0x1f1e6 + 65),
          )
          .join('')
      : '';
    const country = (node.country || flagCode).toUpperCase();
    const prefix =
      node.displayName
        .replace(/[\u{1F1E6}-\u{1F1FF}]/gu, '')
        .trim()
        .split(/\s+[|/–—-]\s+|[|/]/)[0]
        ?.trim() || '';
    const label =
      mode === 'none'
        ? ''
        : mode === 'country'
          ? country || 'Other'
          : prefix || 'Other';
    const members = groups.get(label) || [];
    members.push(node);
    groups.set(label, members);
  }
  return groups;
}
