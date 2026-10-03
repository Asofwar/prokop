// Pinned domains of a rule-list target: the domains of the list with a
// search box, at most MAX_PINNED checked. The domains come from the router
// (autotune/manager.uc list-domains) when a list is chosen.

export const MAX_PINNED = 8;
// Rows rendered at once; the search narrows a long list.
const MAX_ROWS = 300;

export interface ListDomains {
  domains: string[];
  truncated: boolean;
  error: string | null;
}

// The domains shown for a search: pinned ones first (also those the list no
// longer holds), then the matches, at most `limit`.
export function visibleDomains(
  domains: string[],
  pinned: string[],
  query: string,
  limit = MAX_ROWS,
) {
  const q = query.trim().toLowerCase();
  const matches = (d: string) => !q || d.includes(q);
  const first = pinned.filter(matches);
  const rest = domains.filter((d) => matches(d) && !pinned.includes(d));
  const all = [...first, ...rest];
  return {
    shown: all.slice(0, limit),
    hidden: Math.max(all.length - limit, 0),
  };
}

export function createDomainPicker(
  initial: string[],
  load: (tag: string) => Promise<ListDomains>,
  errorText: (reason: string) => string,
) {
  const pinned: string[] = [...initial];
  let domains: string[] = [];
  let tag: string | null = null;
  let note = '';

  const search = E('input', {
    class: 'cbi-input-text',
    type: 'search',
    placeholder: _('Search domains'),
    autocomplete: 'off',
  }) as HTMLInputElement;
  const box = E('div', { class: 'fkp-autotune__domains' }) as HTMLElement;
  const counter = E('div', {
    class: 'fkp-autotune__field-hint',
  }) as HTMLElement;

  const render = () => {
    const { shown, hidden } = visibleDomains(domains, pinned, search.value);
    box.replaceChildren(
      ...shown.map((domain) => {
        const checked = pinned.includes(domain);
        const check = E('input', {
          type: 'checkbox',
          checked: checked ? true : undefined,
          disabled: !checked && pinned.length >= MAX_PINNED ? true : undefined,
        }) as HTMLInputElement;
        check.addEventListener('change', () => {
          const at = pinned.indexOf(domain);
          if (check.checked && at < 0) pinned.push(domain);
          if (!check.checked && at >= 0) pinned.splice(at, 1);
          render();
        });
        return E('label', { class: 'fkp-autotune__domain' }, [
          check,
          ' ',
          domain,
          ...(checked &&
          tag !== null &&
          domains.length &&
          !domains.includes(domain)
            ? [
                ' ',
                E(
                  'span',
                  { class: 'fkp-autotune__muted' },
                  `(${_('not in the list')})`,
                ),
              ]
            : []),
        ]);
      }),
      ...(shown.length
        ? []
        : [
            E(
              'div',
              { class: 'fkp-autotune__muted' },
              note || _('Nothing found'),
            ),
          ]),
    );
    const parts = [
      _('Selected %d of %d')
        .replace('%d', String(pinned.length))
        .replace('%d', String(MAX_PINNED)),
    ];
    if (hidden)
      parts.push(_('%d more: refine the search').replace('%d', String(hidden)));
    if (note && shown.length) parts.push(note);
    counter.textContent = parts.join(' · ');
  };
  search.addEventListener('input', render);

  return {
    element: E('div', {}, [search, box, counter]) as HTMLElement,
    selected: () => [...pinned],
    // Load the domains of a list; choosing another list clears the choice.
    async show(next: string) {
      if (next === tag) return;
      if (tag !== null) pinned.splice(0);
      tag = next;
      domains = [];
      note = _('Loading…');
      render();
      const result = await load(next);
      if (tag !== next) return;
      domains = result.domains;
      note = result.error
        ? errorText(result.error)
        : result.truncated
          ? _('The list is long: only its first 2000 domains can be chosen.')
          : '';
      render();
    },
  };
}
