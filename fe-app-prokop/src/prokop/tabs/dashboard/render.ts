import { renderSections } from './partials';

export function render() {
  return E(
    'div',
    {
      id: 'dashboard-status',
      class: 'fkp_dashboard-page',
    },
    [
      // No live region here: the cards hold controls and refresh with every
      // traffic tick. The warning inside announces itself (role=alert).
      E(
        'div',
        { id: 'dashboard-overview' },
        E('p', { class: 'fkp-overview__hint' }, _('Loading…')),
      ),
    ],
  );
}

// Monitoring → Nodes: the same controller, node selection only.
export function renderNodes() {
  return E('div', { id: 'dashboard-status', class: 'fkp_dashboard-page' }, [
    E(
      'div',
      { id: 'dashboard-sections-grid' },
      renderSections({
        loading: true,
        failed: false,
        section: {
          code: '',
          sectionName: '',
          displayName: '',
          outbounds: [],
          withTagSelect: false,
        },
        onTestLatency: () => {},
        onChooseOutbound: () => {},
        onShowUrlTestInfo: () => {},
        onShowPriorityInfo: () => {},
        onUpdateSubscription: () => {},
        latencyFetching: false,
        latencyProgress: undefined,
        subscriptionUpdating: false,
        selectorSwitchingTag: undefined,
        isPriorityMembersExpanded: () => false,
        onPriorityMembersToggle: () => {},
      }),
    ),
  ]);
}
