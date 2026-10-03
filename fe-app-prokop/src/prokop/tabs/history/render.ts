export function render() {
  const card = (title: string, body: Node[], actions?: Node) =>
    E('section', { class: 'fkp-history__card' }, [
      E('div', { class: 'fkp-history__head' }, [
        E('h3', { class: 'fkp-history__title' }, title),
        ...(actions ? [actions] : []),
      ]),
      ...body,
    ]);

  return E('div', { id: 'history-status', class: 'fkp-history' }, [
    card(_('Protection and recovery'), [
      E('div', { id: 'history-state', role: 'status' }, _('Loading…')),
    ]),
    card(_('History'), [
      E('div', { id: 'history-filter', class: 'fkp-history__filter' }),
      E('div', { id: 'history-events' }, _('Loading…')),
    ]),
    card(
      _('Configuration snapshots'),
      [
        E(
          'p',
          { class: 'fkp-history__hint' },
          _(
            'Changes compare a snapshot with the saved configuration. Unsaved form edits are not included.',
          ),
        ),
        E('div', { id: 'history-snapshots' }, _('Loading…')),
      ],
      E('div', { id: 'history-snapshot-actions', class: 'fkp-actions' }),
    ),
  ]);
}
