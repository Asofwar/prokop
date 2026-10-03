import type { StoreType } from '../../services/store.service';
import type { Prokop } from '../../types';

type SectionsWidget = StoreType['sectionsWidget'];

export function sectionsAfterRefresh(
  current: SectionsWidget,
  data: Prokop.OutboundGroup[],
  now = Date.now(),
): SectionsWidget {
  return {
    ...current,
    loading: false,
    failed: false,
    stale: false,
    updatedAt: now,
    data,
  };
}

// A failed refresh keeps the last nodes on screen but marks them as stale,
// so they are not taken for the current state (UC-122).
export function sectionsAfterFailedRefresh(
  current: SectionsWidget,
): SectionsWidget {
  const hasData = current.data.length > 0;

  return {
    ...current,
    loading: false,
    failed: !hasData,
    stale: hasData,
  };
}

export function formatSectionsUpdatedAt(updatedAt: number) {
  return new Date(updatedAt).toLocaleTimeString([], {
    hour: '2-digit',
    minute: '2-digit',
  });
}

export function renderSectionsStaleNotice(sectionsWidget: SectionsWidget) {
  if (!sectionsWidget.stale || sectionsWidget.updatedAt === null) {
    return null;
  }

  return E(
    'div',
    { class: 'alert-message warning', role: 'status' },
    _('Could not refresh. Showing data from %s').replace(
      '%s',
      formatSectionsUpdatedAt(sectionsWidget.updatedAt),
    ),
  );
}
