import { describe, expect, it } from 'vitest';
import type { StoreType } from '../../../services/store.service';
import type { Prokop } from '../../../types';
import {
  formatSectionsUpdatedAt,
  renderSectionsStaleNotice,
  sectionsAfterFailedRefresh,
  sectionsAfterRefresh,
} from '../sectionsRefresh';

(globalThis as unknown as { E: unknown }).E = (
  tag: string,
  attrs: Record<string, unknown>,
  children: unknown,
) => ({ tag, attrs, children });

const group = {
  code: 'main',
  sectionName: 'main',
  displayName: 'main',
  outbounds: [],
  withTagSelect: false,
} as Prokop.OutboundGroup;

function widget(
  patch: Partial<StoreType['sectionsWidget']> = {},
): StoreType['sectionsWidget'] {
  return {
    loading: false,
    failed: false,
    stale: false,
    updatedAt: null,
    data: [],
    latencyFetchingSections: {},
    latencyProgressSections: {},
    selectorSwitchingSections: {},
    subscriptionUpdatingSections: {},
    ...patch,
  };
}

describe('dashboard sections refresh state', () => {
  it('marks kept data as stale when a refresh fails', () => {
    const loaded = sectionsAfterRefresh(widget(), [group], 1000);
    expect(loaded).toMatchObject({ stale: false, updatedAt: 1000 });

    const failed = sectionsAfterFailedRefresh(loaded);
    expect(failed).toMatchObject({
      failed: false,
      stale: true,
      updatedAt: 1000,
      data: [group],
    });

    expect(sectionsAfterRefresh(failed, [group], 2000)).toMatchObject({
      stale: false,
      updatedAt: 2000,
    });
  });

  it('reports a failure when there is nothing to keep', () => {
    expect(sectionsAfterFailedRefresh(widget())).toMatchObject({
      failed: true,
      stale: false,
    });
  });

  it('renders the time of the last good data only while stale', () => {
    expect(
      renderSectionsStaleNotice(widget({ data: [group], updatedAt: 1000 })),
    ).toBeNull();

    const notice = renderSectionsStaleNotice(
      widget({ data: [group], stale: true, updatedAt: 1000 }),
    ) as unknown as { children: string[] };
    expect(notice.children).toEqual([
      `Could not refresh. Showing data from ${formatSectionsUpdatedAt(1000)}`,
    ]);
  });
});
