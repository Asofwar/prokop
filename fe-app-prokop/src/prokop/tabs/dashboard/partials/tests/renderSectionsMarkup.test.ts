import { afterEach, describe, expect, it, vi } from 'vitest';

import {
  collectInnerHtml,
  collectText,
  luciE,
} from '../../../../../helpers/tests/luciDom';
import { Prokop } from '../../../../types';
import { renderSections } from '../renderSections';

vi.mock('../../../../../icons', () => ({
  renderLoaderCircleIcon24: () => '',
  renderInfoIcon24: () => '',
}));
vi.mock('../../../../../helpers', () => ({ svgEl: () => '' }));

afterEach(() => vi.unstubAllGlobals());

// FE-1: a subscription provider controls profile-title, announce and node
// names. LuCI's E() parses a bare string child as HTML, so all of it must be
// handed over as text.
describe('dashboard sections with hostile subscription text', () => {
  it('renders provider metadata and node names as text', () => {
    vi.stubGlobal('E', luciE);
    const payload = '<img src=x onerror=alert(1)>';
    const node: Prokop.Outbound = {
      code: 'node-a',
      displayName: `${payload} Node`,
      latency: 30,
      type: 'VLESS',
      selected: true,
    };

    const rendered = renderSections({
      loading: false,
      failed: false,
      section: {
        code: 'proxy',
        sectionName: 'main',
        displayName: `${payload} Section`,
        outbounds: [node],
        withTagSelect: true,
        subscriptionMetadata: [
          {
            version: 1,
            title: `${payload} Title`,
            announce: `${payload} Announce`,
            traffic: { used: 1, total: 2 },
          },
        ],
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
    });

    const html = collectInnerHtml(rendered);
    expect(html.filter((value) => value.includes('<'))).toEqual([]);
    const text = collectText(rendered);
    expect(text).toContain(`${payload} Title`);
    expect(text).toContain(`${payload} Announce`);
    expect(text).toContain(`${payload} Node`);
  });
});
