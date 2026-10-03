import { renderLoaderCircleIcon24, renderInfoIcon24 } from '../../../../icons';
import { svgEl } from '../../../../helpers';
import { prettyBytes } from '../../../../helpers/prettyBytes';
import { Prokop } from '../../../types';
import { renderFlagEmojis } from './renderFlagEmojis';
import { getOutboundFooterLabel } from './getOutboundFooterLabel';

interface IRenderSectionsProps {
  loading: boolean;
  failed: boolean;
  section: Prokop.OutboundGroup;
  onTestLatency: (tag: string | string[]) => void;
  onChooseOutbound: (
    sectionName: string,
    selector: string,
    tag: string,
  ) => void;
  onShowUrlTestInfo: (outbound: Prokop.Outbound) => void;
  onShowPriorityInfo: (outbound: Prokop.Outbound) => void;
  onUpdateSubscription: (section: Prokop.OutboundGroup) => void;
  latencyFetching: boolean;
  latencyProgress?: Prokop.LatencyActionProgress;
  subscriptionUpdating: boolean;
  selectorSwitchingTag?: string;
  isPriorityMembersExpanded: (outbound: Prokop.Outbound) => boolean;
  onPriorityMembersToggle: (outbound: Prokop.Outbound, open: boolean) => void;
  // Read-only sessions see the runtime state but get no runtime controls.
  readonly?: boolean;
  // Prokop is stopped: the nodes cannot be fetched, so say so instead of
  // showing a skeleton or stale cards. stoppedActions offers to start it.
  stopped?: boolean;
  stoppedActions?: HTMLElement[];
}

function renderFailedState() {
  return E(
    'div',
    {
      class: 'fkp_dashboard-page__outbound-section centered',
      style: 'height: 127px',
    },
    E('span', {}, [E('span', {}, _('Dashboard currently unavailable'))]),
  );
}

function renderStoppedState(actions: HTMLElement[] = []) {
  return E(
    'div',
    {
      class: 'fkp_dashboard-page__outbound-section centered',
      style: 'min-height: 127px',
    },
    E('div', { class: 'fkp_dashboard-page__stopped' }, [
      E(
        'span',
        {},
        _(
          'Prokop service is stopped. Start the service to display nodes and groups.',
        ),
      ),
      ...actions,
    ]),
  );
}

function renderLoadingState() {
  return E('div', {
    id: 'dashboard-sections-grid-skeleton',
    class: 'fkp_dashboard-page__outbound-section skeleton',
    style: 'height: 127px',
  });
}

function isValidHttpUrl(url?: string) {
  return Boolean(url && /^https?:\/\/\S+$/i.test(url));
}

function formatBytes(value?: number) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
    return undefined;
  }

  return prettyBytes(value);
}

function formatDate(seconds?: number) {
  if (
    typeof seconds !== 'number' ||
    !Number.isFinite(seconds) ||
    seconds <= 0
  ) {
    return undefined;
  }

  const date = new Date(seconds * 1000);
  if (Number.isNaN(date.getTime())) {
    return undefined;
  }

  return date.toLocaleDateString(undefined, {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  });
}

function renderMetadataAction(label: string, url?: string) {
  if (!isValidHttpUrl(url)) {
    return undefined;
  }

  return E(
    'a',
    {
      class: 'btn fkp_dashboard-page__subscription-meta__action',
      href: url,
      target: '_blank',
      rel: 'noopener noreferrer',
      title: label,
      'aria-label': label,
    },
    label,
  );
}

function renderSubscriptionMetadata(
  metadata: Prokop.SubscriptionMetadata | undefined,
) {
  if (!metadata || Object.keys(metadata).length <= 1) {
    return undefined;
  }

  const title = metadata.title || metadata.fileName;
  const traffic = metadata.traffic;
  const used = formatBytes(traffic?.used) || '0 B';
  const total = traffic?.isUnlimited
    ? '∞'
    : formatBytes(traffic?.total) || '0 B';
  const expire = formatDate(metadata.expire);
  const refillDate = formatDate(metadata.refillDate);

  const rows = [
    traffic
      ? {
          label: _('Traffic'),
          value: `${used} / ${total}`,
        }
      : undefined,
    expire ? { label: _('Expires'), value: expire } : undefined,
    refillDate ? { label: _('Refill'), value: refillDate } : undefined,
  ].filter(Boolean) as { label: string; value: string }[];

  const actions = [
    renderMetadataAction(_('Profile'), metadata.webPageUrl),
    renderMetadataAction(_('Support'), metadata.supportUrl),
    renderMetadataAction(_('More details'), metadata.announceUrl),
  ].filter(Boolean) as HTMLElement[];

  return E('div', { class: 'fkp_dashboard-page__subscription-meta' }, [
    E('div', { class: 'fkp_dashboard-page__subscription-meta__main' }, [
      E(
        'div',
        { class: 'fkp_dashboard-page__subscription-meta__heading' },
        _('Subscription info:'),
      ),
      title
        ? E(
            'div',
            { class: 'fkp_dashboard-page__subscription-meta__title' },
            title,
          )
        : '',
      rows.length
        ? E(
            'div',
            { class: 'fkp_dashboard-page__subscription-meta__facts' },
            rows.map((row) =>
              E(
                'div',
                { class: 'fkp_dashboard-page__subscription-meta__fact' },
                [
                  E(
                    'span',
                    {
                      class: 'fkp_dashboard-page__subscription-meta__fact-key',
                    },
                    row.label,
                  ),
                  E(
                    'span',
                    {
                      class:
                        'fkp_dashboard-page__subscription-meta__fact-value',
                    },
                    row.value,
                  ),
                ],
              ),
            ),
          )
        : '',
      actions.length
        ? E(
            'div',
            { class: 'fkp_dashboard-page__subscription-meta__actions' },
            actions,
          )
        : '',
    ]),
    metadata.announce
      ? E(
          'blockquote',
          { class: 'fkp_dashboard-page__subscription-meta__announce' },
          metadata.announce,
        )
      : '',
  ]);
}

function renderSubscriptionUpdateAction(
  section: Prokop.OutboundGroup,
  subscriptionUpdating: boolean,
  onUpdateSubscription: (section: Prokop.OutboundGroup) => void,
) {
  if (!section.subscriptionSourceCount) {
    return undefined;
  }

  return E(
    'button',
    {
      type: 'button',
      class: 'btn fkp_dashboard-page__outbound-section__subscription-update',
      'aria-label': _('Update subscriptions'),
      disabled: subscriptionUpdating ? true : undefined,
      click: (event: MouseEvent) => {
        event.preventDefault();
        event.stopPropagation();
        if (subscriptionUpdating) {
          return;
        }

        onUpdateSubscription(section);
      },
    },
    subscriptionUpdating
      ? [renderLoaderCircleIcon24(), _('Update subscriptions')]
      : _('Update subscriptions'),
  );
}

export function getLatencyTestLabel(
  latencyProgress?: Prokop.LatencyActionProgress,
) {
  const total = Math.trunc(Number(latencyProgress?.total ?? 0));
  if (!Number.isFinite(total) || total <= 0) {
    return _('Test latency');
  }

  const completedValue = Number(latencyProgress?.completed ?? 0);
  const completed = Number.isFinite(completedValue)
    ? Math.trunc(completedValue)
    : 0;

  return `${_('Test latency')}: ${Math.min(
    Math.max(0, completed),
    total,
  )}/${total}`;
}

function renderDefaultState({
  section,
  onChooseOutbound,
  onShowUrlTestInfo,
  onShowPriorityInfo,
  onTestLatency,
  onUpdateSubscription,
  latencyFetching,
  latencyProgress,
  subscriptionUpdating,
  selectorSwitchingTag,
  isPriorityMembersExpanded,
  onPriorityMembersToggle,
  readonly = false,
}: IRenderSectionsProps) {
  const withTagSelect = section.withTagSelect && !readonly;

  function renderPriorityMembers(outbound: Prokop.Outbound) {
    const members = outbound.priorityInfo?.outbounds || [];

    if (members.length === 0) {
      return undefined;
    }

    let previousLevel = -1;
    const content: HTMLElement[] = [];

    members.forEach((member, index) => {
      if (member.levelIndex !== previousLevel) {
        previousLevel = member.levelIndex;
        content.push(
          E(
            'div',
            { class: 'fkp_dashboard-page__priority-members__level' },
            `${_('Priority')} #${member.levelIndex + 1}: ${member.levelName}`,
          ),
        );
      }

      content.push(
        E(
          'div',
          {
            class: [
              'fkp_dashboard-page__priority-members__row',
              member.selected
                ? 'fkp_dashboard-page__priority-members__row--selected'
                : '',
            ]
              .filter(Boolean)
              .join(' '),
          },
          [
            E(
              'span',
              { class: 'fkp_dashboard-page__priority-members__order' },
              String(index + 1),
            ),
            E(
              'span',
              { class: 'fkp_dashboard-page__priority-members__name' },
              renderFlagEmojis(member.displayName),
            ),
            E(
              'span',
              {
                class: member.latency
                  ? 'fkp_dashboard-page__outbound-grid__item__latency--green'
                  : 'fkp_dashboard-page__outbound-grid__item__latency--empty',
              },
              member.latency
                ? _('%d ms').replace('%d', String(member.latency))
                : '—',
            ),
          ],
        ),
      );
    });

    const details = E(
      'details',
      {
        class: 'fkp_dashboard-page__priority-members',
        // LuCI E() writes false as an attribute too; absent means collapsed.
        open: isPriorityMembersExpanded(outbound) ? true : undefined,
        click: (event: Event) => event.stopPropagation(),
      },
      [
        E('summary', {}, `${_('Nodes')}: ${members.length}`),
        E(
          'div',
          { class: 'fkp_dashboard-page__priority-members__list' },
          content,
        ),
      ],
    );
    details.addEventListener('toggle', () => {
      onPriorityMembersToggle(outbound, details.open);
    });
    return details;
  }

  function testLatency() {
    if (section.withTagSelect) {
      return onTestLatency(
        section.latencyTestCodes?.length
          ? section.latencyTestCodes
          : section.latencyTestCode || section.code,
      );
    }

    if (section.outbounds.length) {
      return onTestLatency(section.outbounds[0].code);
    }
  }

  function renderOutbound(outbound: Prokop.Outbound) {
    function getLatencyClass() {
      if (!outbound.latency) {
        return 'fkp_dashboard-page__outbound-grid__item__latency--empty';
      }

      if (outbound.latency < 800) {
        return 'fkp_dashboard-page__outbound-grid__item__latency--green';
      }

      if (outbound.latency < 1500) {
        return 'fkp_dashboard-page__outbound-grid__item__latency--yellow';
      }

      return 'fkp_dashboard-page__outbound-grid__item__latency--red';
    }

    const footerLabel = getOutboundFooterLabel(outbound);
    const priorityMembers = renderPriorityMembers(outbound);
    const selectorSwitching = Boolean(selectorSwitchingTag);
    const outboundSwitching = selectorSwitchingTag === outbound.code;
    const canChooseOutbound =
      withTagSelect &&
      outbound.runtimeAvailable !== false &&
      !selectorSwitching &&
      !outbound.selected;
    const className = [
      'fkp_dashboard-page__outbound-grid__item',
      outbound.selected
        ? 'fkp_dashboard-page__outbound-grid__item--active'
        : '',
      canChooseOutbound
        ? 'fkp_dashboard-page__outbound-grid__item--selectable'
        : '',
      withTagSelect && !canChooseOutbound
        ? 'fkp_dashboard-page__outbound-grid__item--disabled'
        : '',
      outboundSwitching
        ? 'fkp_dashboard-page__outbound-grid__item--switching'
        : '',
    ]
      .filter(Boolean)
      .join(' ');
    const chooseOutbound = () =>
      canChooseOutbound &&
      onChooseOutbound(section.sectionName, section.code, outbound.code);
    // Selector cards act as toggle buttons: reachable with Tab and operable
    // with Enter or Space, like the click.
    return E(
      'div',
      {
        class: className,
        role: withTagSelect ? 'button' : undefined,
        tabIndex: canChooseOutbound ? 0 : undefined,
        'aria-pressed': withTagSelect
          ? String(Boolean(outbound.selected))
          : undefined,
        'aria-busy': outboundSwitching ? 'true' : undefined,
        'aria-disabled':
          withTagSelect && !canChooseOutbound ? 'true' : undefined,
        click: chooseOutbound,
        keydown: (event: KeyboardEvent) => {
          if (event.target !== event.currentTarget) return;
          if (event.key !== 'Enter' && event.key !== ' ') return;
          event.preventDefault();
          chooseOutbound();
        },
      },
      [
        ...(outboundSwitching
          ? [
              svgEl(
                'svg',
                { class: 'fkp_dashboard-page__outbound-grid__item__snake' },
                [
                  svgEl('rect', {
                    width: '100%',
                    height: '100%',
                    fill: 'none',
                    rx: 4,
                    ry: 4,
                    pathLength: 100,
                  }),
                ],
              ),
            ]
          : []),
        E('div', { class: 'fkp_dashboard-page__outbound-grid__item__header' }, [
          E('b', {}, renderFlagEmojis(outbound.displayName)),
          ...(outbound.urlTestInfo
            ? [
                E(
                  'button',
                  {
                    type: 'button',
                    class:
                      'btn fkp_dashboard-page__outbound-grid__item__copy-button',
                    title: _('URLTest details'),
                    'aria-label': _('URLTest details'),
                    click: (event: MouseEvent) => {
                      event.stopPropagation();
                      onShowUrlTestInfo(outbound);
                    },
                  },
                  renderInfoIcon24(),
                ),
              ]
            : []),
          ...(outbound.priorityInfo
            ? [
                E(
                  'button',
                  {
                    type: 'button',
                    class:
                      'btn fkp_dashboard-page__outbound-grid__item__copy-button',
                    title: _('Priority details'),
                    'aria-label': _('Priority details'),
                    click: (event: MouseEvent) => {
                      event.stopPropagation();
                      onShowPriorityInfo(outbound);
                    },
                  },
                  renderInfoIcon24(),
                ),
              ]
            : []),
        ]),
        E('div', { class: 'fkp_dashboard-page__outbound-grid__item__footer' }, [
          E(
            'div',
            { class: 'fkp_dashboard-page__outbound-grid__item__type' },
            renderFlagEmojis(footerLabel),
          ),
          E(
            'div',
            { class: getLatencyClass() },
            outbound.latency
              ? _('%d ms').replace('%d', String(outbound.latency))
              : '—',
          ),
        ]),
        ...(priorityMembers ? [priorityMembers] : []),
      ],
    );
  }

  const metadataNodes = (section.subscriptionMetadata || [])
    .map((metadata) => renderSubscriptionMetadata(metadata))
    .filter(Boolean) as HTMLElement[];
  const subscriptionUpdateAction = readonly
    ? undefined
    : renderSubscriptionUpdateAction(
        section,
        subscriptionUpdating,
        onUpdateSubscription,
      );

  return E('div', { class: 'fkp_dashboard-page__outbound-section' }, [
    // Title with test latency
    E('div', { class: 'fkp_dashboard-page__outbound-section__title-section' }, [
      E(
        'div',
        {
          class: 'fkp_dashboard-page__outbound-section__title-section__title',
        },
        section.displayName,
      ),
      E(
        'div',
        {
          class: 'fkp_dashboard-page__outbound-section__title-section__actions',
        },
        [
          ...(subscriptionUpdateAction ? [subscriptionUpdateAction] : []),
          ...(readonly
            ? []
            : [
                E(
                  'button',
                  {
                    type: 'button',
                    class: 'btn dashboard-sections-grid-item-test-latency',
                    'data-latency-section': section.sectionName,
                    disabled: latencyFetching ? true : undefined,
                    click: (event: MouseEvent) => {
                      event.preventDefault();
                      event.stopPropagation();
                      if (latencyFetching) {
                        return;
                      }

                      testLatency();
                    },
                  },
                  latencyFetching
                    ? [
                        renderLoaderCircleIcon24(),
                        E(
                          'span',
                          {
                            class:
                              'dashboard-sections-grid-item-test-latency__label',
                          },
                          getLatencyTestLabel(latencyProgress),
                        ),
                      ]
                    : E(
                        'span',
                        {
                          class:
                            'dashboard-sections-grid-item-test-latency__label',
                        },
                        _('Test latency'),
                      ),
                ),
              ]),
        ],
      ),
    ]),
    E('div', { class: 'fkp_dashboard-page__outbound-grid' }, [
      ...metadataNodes,
      ...section.outbounds.map((outbound) => renderOutbound(outbound)),
    ]),
  ]);
}

export function renderSections(props: IRenderSectionsProps) {
  if (props.stopped) {
    return renderStoppedState(props.stoppedActions);
  }

  if (props.failed) {
    return renderFailedState();
  }

  if (props.loading) {
    return renderLoadingState();
  }

  return renderDefaultState(props);
}
