import { afterEach, describe, expect, it, vi } from 'vitest';

import { collectText, luciE } from '../../../../../helpers/tests/luciDom';
import { Prokop } from '../../../../types';
import { renderSections, subscriptionNoticeText } from '../renderSections';
import { getSubscriptionNotices } from '../../../../methods/custom/getDashboardSections';

vi.mock('../../../../../icons', () => ({
  renderLoaderCircleIcon24: () => '',
  renderInfoIcon24: () => '',
}));
vi.mock('../../../../../helpers', () => ({ svgEl: () => '' }));

afterEach(() => vi.unstubAllGlobals());

function render(section: Partial<Prokop.OutboundGroup>) {
  vi.stubGlobal('E', luciE);
  return collectText(
    renderSections({
      loading: false,
      failed: false,
      section: {
        code: 'proxy',
        sectionName: 'main',
        displayName: 'Main',
        withTagSelect: true,
        outbounds: [],
        ...section,
      } as Prokop.OutboundGroup,
      onTestLatency: () => {},
      onChooseOutbound: () => {},
      onShowUrlTestInfo: () => {},
      onShowPriorityInfo: () => {},
      onUpdateSubscription: () => {},
      latencyFetching: false,
      subscriptionUpdating: false,
      isPriorityMembersExpanded: () => false,
      onPriorityMembersToggle: () => {},
    }),
  );
}

// R6, R1, adjacent 9: the dashboard says why servers of a subscription are
// missing, and marks a server that runs without certificate verification.
describe('subscription notices on the dashboard', () => {
  it('explains the server limit, placeholders and refused pins', () => {
    const text = render({
      subscriptionSourceCount: 2,
      subscriptionNotices: [
        {
          kind: 'node_limit',
          sourceIndex: 1,
          limit: 500,
          total: 601,
          dropped: 101,
        },
        { kind: 'placeholders', sourceIndex: 2, count: 3 },
        { kind: 'certificate_pin', sourceIndex: 2, count: 1 },
        { kind: 'large_source', sourceIndex: 2, total: 900, suggested: 500 },
      ],
    });
    expect(text).toContain('Subscription 1: Only the first 500 of 601 servers');
    expect(text).toContain('101 were left out');
    expect(text).toContain(
      'Subscription 2: The subscription sent 3 placeholder entries',
    );
    expect(text).toContain('certificate pin needs sing-box 1.15.0');
    expect(text).toContain(
      'This subscription has 900 servers and no server limit',
    );
  });

  it('has no source prefix for a single source and ignores unknown kinds', () => {
    expect(
      subscriptionNoticeText(
        { kind: 'placeholders', sourceIndex: 1, count: 2 },
        1,
      ),
    ).toMatch(/^The subscription sent 2 placeholder/);
    expect(
      subscriptionNoticeText(
        { kind: 'other' } as unknown as Prokop.SubscriptionNotice,
        1,
      ),
    ).toBe('');
  });

  it('marks a server without certificate verification', () => {
    const text = render({
      outbounds: [
        {
          code: 'a',
          displayName: 'A',
          latency: 0,
          type: 'Trojan',
          selected: true,
          insecure: true,
        },
        {
          code: 'b',
          displayName: 'B',
          latency: 0,
          type: 'Trojan',
          selected: false,
        },
      ],
    });
    expect(text.match(/Certificate not verified/g)).toHaveLength(1);
  });

  it('keeps only the notices of the current sources', () => {
    const notices = getSubscriptionNotices(
      { '.name': 'main', '.type': 'section' } as Prokop.ConfigSection,
      1,
      {
        subscriptionNotices: [
          {
            kind: 'node_limit',
            sourceIndex: 1,
            sourceSection: 'main-subscription-1',
            limit: 1,
            total: 2,
            dropped: 1,
          },
          {
            kind: 'node_limit',
            sourceIndex: 2,
            sourceSection: 'main-subscription-2',
            limit: 1,
            total: 2,
            dropped: 1,
          },
          {
            kind: 'bogus',
            sourceIndex: 1,
            sourceSection: 'main-subscription-1',
          } as unknown as Prokop.SubscriptionNotice,
        ],
      },
    );
    expect(notices?.map((notice) => notice.sourceIndex)).toEqual([1]);
  });
});
