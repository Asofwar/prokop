import { afterEach, describe, expect, it, vi } from 'vitest';

import { Prokop } from '../../../../types';
import { createPriorityMembersState } from '../../priorityMembersState';
import { renderSections } from '../renderSections';

vi.mock('../../../../../icons', () => ({
  renderLoaderCircleIcon24: () => '',
  renderInfoIcon24: () => '',
}));
vi.mock('../../../../../helpers', () => ({ svgEl: () => '' }));

afterEach(() => vi.unstubAllGlobals());

describe('Priority member disclosure', () => {
  it('starts collapsed and retains toggles across dashboard card replacements', () => {
    const state = createPriorityMembersState();
    const priority: Prokop.Outbound = {
      code: 'priority',
      displayName: 'Priority',
      latency: 30,
      type: 'Priority',
      selected: true,
      priorityInfo: {
        code: 'priority',
        displayName: 'Priority',
        selectedName: 'Node A',
        outbounds: [
          {
            code: 'node-a',
            displayName: 'Node A',
            latency: 30,
            selected: true,
            type: 'VLESS',
            levelIndex: 0,
            levelName: 'Primary',
          },
        ],
      },
    };
    let detailsAttributes: Record<string, unknown> = {};
    let details: {
      open: boolean;
      listeners: Record<string, () => void>;
    };
    vi.stubGlobal('E', (tag: string, attributes: Record<string, unknown>) => {
      if (tag === 'details') {
        detailsAttributes = attributes;
        details = {
          // Model LuCI's boolean HTML attribute semantics.
          open: attributes.open != null,
          listeners: {},
        };
        return Object.assign(details, {
          addEventListener: (name: string, callback: () => void) => {
            details.listeners[name] = callback;
          },
        });
      }
      return { tag, attributes };
    });
    const render = () => {
      renderSections({
        loading: false,
        failed: false,
        section: {
          code: 'proxy',
          sectionName: 'main',
          displayName: 'Main',
          outbounds: [priority],
          withTagSelect: true,
        },
        onTestLatency: () => {},
        onChooseOutbound: () => {},
        onShowUrlTestInfo: () => {},
        onShowPriorityInfo: () => {},
        onUpdateSubscription: () => {},
        latencyFetching: false,
        subscriptionUpdating: false,
        isPriorityMembersExpanded: (outbound) =>
          state.isExpanded('main', outbound.code),
        onPriorityMembersToggle: (outbound, open) =>
          state.setExpanded('main', outbound.code, open),
      });
    };
    const toggle = (open: boolean) => {
      details.open = open;
      details.listeners.toggle();
    };

    render();
    // LuCI E() must omit this boolean attribute, not write open="false".
    expect(detailsAttributes.open).toBeUndefined();
    expect(details!.open).toBe(false);
    expect(details!.listeners.toggle).toBeTypeOf('function');
    expect(detailsAttributes.ontoggle).toBeUndefined();

    toggle(true);
    render();
    expect(detailsAttributes.open).toBe(true);
    render();
    expect(detailsAttributes.open).toBe(true);

    toggle(false);
    render();
    expect(detailsAttributes.open).toBeUndefined();

    const stopPropagation = vi.fn();
    (detailsAttributes.click as (event: Event) => void)({
      stopPropagation,
    } as unknown as Event);
    expect(stopPropagation).toHaveBeenCalledOnce();
  });

  it('keeps group states independent across sections and ambiguous names', () => {
    const state = createPriorityMembersState();
    state.setExpanded('main', 'priority', true);
    expect(state.isExpanded('other', 'priority')).toBe(false);
    expect(state.isExpanded('main', 'other')).toBe(false);

    state.setExpanded('main:extra', 'priority', true);
    expect(state.isExpanded('main', 'extra:priority')).toBe(false);
    state.setExpanded('main', 'priority', false);
    expect(state.isExpanded('main', 'priority')).toBe(false);
    expect(state.isExpanded('main:extra', 'priority')).toBe(true);
  });
});
