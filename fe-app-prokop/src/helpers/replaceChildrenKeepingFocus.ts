const FOCUSABLE =
  'a[href], button, input, select, textarea, summary, [tabindex]';

// Identifies a control by what the user sees, so its re-rendered twin can be
// found in the new DOM.
function focusKey(element: Element) {
  return [
    element.tagName,
    element.id,
    element.getAttribute('name') || '',
    element.getAttribute('href') || '',
    element.getAttribute('aria-label') || '',
    (element.textContent || '').trim(),
  ].join('|');
}

function focusables(container: Element) {
  return Array.from(container.querySelectorAll(FOCUSABLE));
}

// Periodic refreshes rebuild whole blocks. Replacing the node that holds
// keyboard focus drops focus to <body>, so move it to the matching control
// in the new content: the same control by key, or, when only labels changed
// (a button now reads "Applying…"), the control at the same position.
export function replaceChildrenKeepingFocus(
  container: Element,
  ...nodes: Node[]
) {
  const active = container.ownerDocument?.activeElement;

  if (!active || active === container || !container.contains(active)) {
    container.replaceChildren(...nodes);
    return;
  }

  const before = focusables(container);
  const position = before.indexOf(active);
  const key = focusKey(active);
  const occurrence = before
    .slice(0, Math.max(position, 0))
    .filter((element) => focusKey(element) === key).length;

  container.replaceChildren(...nodes);

  const after = focusables(container);
  const target =
    after.filter((element) => focusKey(element) === key)[occurrence] ||
    (position >= 0 && after.length === before.length
      ? after[position]
      : undefined);

  (target as HTMLElement | undefined)?.focus?.({ preventScroll: true });
}
