export function render() {
  const card = (title: string, body: Node[], actions?: Node) =>
    E('section', { class: 'fkp-autotune__card' }, [
      E('div', { class: 'fkp-autotune__head' }, [
        E('h3', { class: 'fkp-autotune__title' }, title),
        ...(actions ? [actions] : []),
      ]),
      ...body,
    ]);

  return E('div', { id: 'autotune-status', class: 'fkp-autotune' }, [
    card(
      _('Mode and state'),
      [E('div', { id: 'autotune-state' }, _('Loading…'))],
      E('div', { id: 'autotune-state-actions', class: 'fkp-actions' }),
    ),
    card(_('DPI rule groups'), [
      E(
        'p',
        { class: 'fkp-autotune__hint' },
        _(
          'A group is one Zapret DPI rule. Prokop changes only the strategy of an existing rule, for all its targets at once. It never creates or deletes rules and never turns DPI bypass off.',
        ),
      ),
      E('div', { id: 'autotune-groups' }, _('Loading…')),
    ]),
    card(
      _('Targets'),
      [E('div', { id: 'autotune-targets' }, _('Loading…'))],
      E('div', { id: 'autotune-target-actions', class: 'fkp-actions' }),
    ),
    card(_('Autotune history'), [
      E('div', { id: 'autotune-history' }, _('Loading…')),
    ]),
  ]);
}
