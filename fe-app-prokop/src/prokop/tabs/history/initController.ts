import { asText } from '../../../helpers/asText';
import { isPageHidden } from '../../../helpers/isPageHidden';
import { onMount, preserveScrollForPage } from '../../../helpers';
import { replaceChildrenKeepingFocus } from '../../../helpers/replaceChildrenKeepingFocus';
import { showToast } from '../../../helpers/showToast';
import { ProkopShellMethods } from '../../methods';
import { logger, store, StoreType } from '../../services';
import { isReadonlyMode } from '../../services/accessMode.service';
import { refreshRuntimeUiState } from '../../services/runtimeUiState.service';
import { isActiveLuciTab } from '../../helpers/isActiveLuciTab';
import { Prokop } from '../../types';
import { confirmAction } from '../../ui/confirmAction';
import { renderOverflowMenu } from '../../ui/overflowMenu';
import { renderStatus } from '../../ui/status';
import {
  renderEmptyState,
  renderErrorState,
  renderLoadingState,
} from '../../ui/states';
import {
  clearHistoryToast,
  clearSnapshotsToast,
  createSnapshotToast,
  DEFAULT_RETENTION,
  deleteSnapshotToast,
  diffRows,
  diffTruncatedText,
  historyFilterLabel,
  historyItems,
  HISTORY_PAGE_SIZE,
  parseRetentionInput,
  recoveryRows,
  removableSnapshots,
  RETENTION_BOUNDS,
  retentionConsequences,
  retentionToast,
  restoreConfirmMessage,
  restoreMigrationNote,
  restorePreview,
  restoreResultToast,
  snapshotDiff,
  snapshotRows,
  SNAPSHOTS_COLLAPSED,
  unsavedChangesBlockRestore,
  unsavedChangesText,
  type HistoryFilter,
  type SnapshotDiff,
} from './model';
import { PROKOP_UCI_PACKAGE } from '../../../constants';

const REFRESH_INTERVAL_MS = 15000;
const FILTERS: HistoryFilter[] = ['all', 'config', 'service', 'autotune'];
const MAX_RESTORE_PREVIEW = 8;

let mounted = false;
let mountId = 0;
let refreshTimer: ReturnType<typeof setInterval> | null = null;
let filter: HistoryFilter = 'all';
let health: Prokop.HealthStatus | null = null;
let healthFailed = false;
let history: Prokop.HistoryResult | null = null;
let historyFailed = false;
let snapshots: Prokop.SnapshotMetadata[] | null = null;
let snapshotsFailed = false;
let snapshotBusy = false;
// How many history records the list shows; whether the snapshot list shows
// all of them. Both keep the page short.
let historyShown = HISTORY_PAGE_SIZE;
let snapshotsExpanded = false;
// The Retention card's fields while the user edits them, so a refresh does
// not overwrite what is typed.
let retentionDraft: { history: string; snapshots: string } | null = null;
let retentionError = '';

async function loadAll() {
  const id = mountId;
  const [healthResponse, historyResponse, snapshotResponse] =
    await Promise.allSettled([
      ProkopShellMethods.getHealthStatus(),
      ProkopShellMethods.getHistory(),
      ProkopShellMethods.snapshotList(),
    ]);
  if (!mounted || id !== mountId) return;

  const value = <T>(result: PromiseSettledResult<Prokop.MethodResponse<T>>) =>
    result.status === 'fulfilled' && result.value.success
      ? result.value.data
      : null;

  health = value(healthResponse);
  healthFailed = !health;
  history = value(historyResponse);
  historyFailed = !history || !Array.isArray(history.events);
  const list = value(snapshotResponse);
  snapshots = Array.isArray(list) ? list : null;
  snapshotsFailed = !snapshots;
  renderAll();
}

function replace(id: string, ...nodes: Node[]) {
  const container = document.getElementById(id);
  if (container)
    preserveScrollForPage(() =>
      replaceChildrenKeepingFocus(container, ...nodes),
    );
}

function renderState() {
  if (healthFailed || !health) {
    replace(
      'history-state',
      healthFailed
        ? renderErrorState(
            _('Recovery state is unavailable'),
            () => void loadAll(),
          )
        : renderLoadingState(),
    );
    return;
  }

  replace(
    'history-state',
    E(
      'dl',
      { class: 'fkp-history__facts' },
      recoveryRows(health, snapshots).flatMap((row) => [
        E('dt', {}, asText(row.label)),
        E('dd', {}, renderStatus({ label: row.value, tone: row.tone })),
      ]),
    ),
  );
}

function renderHistory() {
  replace(
    'history-filter',
    ...FILTERS.map((item) =>
      E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button',
          'aria-pressed': item === filter ? 'true' : 'false',
          click: () => {
            filter = item;
            historyShown = HISTORY_PAGE_SIZE;
            renderHistory();
          },
        },
        asText(historyFilterLabel(item)),
      ),
    ),
  );

  const readonly = isReadonlyMode();
  replace(
    'history-actions',
    ...(readonly
      ? []
      : [
          E(
            'button',
            {
              type: 'button',
              class: 'btn cbi-button',
              disabled:
                snapshotBusy || !history?.persistent || !history.events.length
                  ? true
                  : undefined,
              title: history?.persistent
                ? undefined
                : _('History is kept in memory until the router restarts.'),
              click: () => void clearHistory(),
            },
            _('Clear…'),
          ),
        ]),
  );

  if (historyFailed || !history) {
    replace(
      'history-events',
      historyFailed
        ? renderErrorState(_('History is unavailable'), () => void loadAll())
        : renderLoadingState(),
    );
    return;
  }

  const items = historyItems(history.events, filter);
  const visible = items.slice(0, historyShown);
  const notes = history.persistent
    ? []
    : [
        E(
          'p',
          { class: 'fkp-history__hint' },
          _('History is kept in memory until the router restarts.'),
        ),
      ];

  replace(
    'history-events',
    ...notes,
    items.length
      ? E(
          'ul',
          { class: 'fkp-history__list' },
          visible.map((item) =>
            E('li', { class: 'fkp-history__event' }, [
              E(
                'span',
                { class: 'fkp-history__time', title: item.time },
                asText(item.relative),
              ),
              E('span', { class: 'fkp-history__what' }, asText(item.title)),
              renderStatus(item.outcome),
              ...(item.details.length
                ? [
                    E(
                      'ul',
                      { class: 'fkp-history__details' },
                      item.details.map((line) => E('li', {}, [line])),
                    ),
                  ]
                : []),
            ]),
          ),
        )
      : renderEmptyState(
          filter === 'all'
            ? _('No events recorded yet')
            : _('No events of this kind'),
        ),
    ...(items.length > visible.length
      ? [
          E('div', { class: 'fkp-history__more' }, [
            E(
              'span',
              { class: 'fkp-history__hint' },
              _('Shown %d of %d')
                .replace('%d', String(visible.length))
                .replace('%d', String(items.length)),
            ),
            E(
              'button',
              {
                type: 'button',
                class: 'btn cbi-button',
                click: () => {
                  historyShown += HISTORY_PAGE_SIZE;
                  renderHistory();
                },
              },
              _('Show more'),
            ),
          ]),
        ]
      : []),
  );
}

function renderDiffTable(diff: SnapshotDiff) {
  const rows = diffRows(diff.changes);
  if (!diff.total) {
    return E('p', {}, _('No saved changes since this snapshot'));
  }

  return E('div', { class: 'fkp-history__diff-wrap' }, [
    // UC-062: a cut list says it is not the whole change.
    ...(diff.total > rows.length
      ? [E('p', {}, asText(diffTruncatedText(diff)))]
      : []),
    E('table', { class: 'table fkp-history__diff' }, [
      E('tr', { class: 'tr table-titles' }, [
        E('th', { class: 'th' }, _('Setting')),
        E('th', { class: 'th' }, _('In snapshot')),
        E('th', { class: 'th' }, _('Now')),
      ]),
      ...rows.map((row) =>
        E('tr', { class: 'tr' }, [
          E('td', { class: 'td' }, asText(row.where)),
          E('td', { class: 'td' }, asText(row.snapshot)),
          E('td', { class: 'td' }, asText(row.current)),
        ]),
      ),
    ]),
  ]);
}

async function loadDiff(id: string) {
  const response = await ProkopShellMethods.snapshotDiff(id);
  return response.success && Array.isArray(response.data)
    ? snapshotDiff(response.data)
    : null;
}

async function showChanges(id: string) {
  const diff = await loadDiff(id);
  if (!diff) {
    showToast(_('Could not compare configurations'), 'error');
    return;
  }

  ui.showModal(_('Changes since this snapshot'), [
    renderDiffTable(diff),
    E('div', { class: 'right fkp-confirm__actions' }, [
      E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button',
          click: () => ui.hideModal(),
        },
        _('Close'),
      ),
    ]),
  ] as unknown as HTMLElement);
}

async function runSnapshotAction(action: () => Promise<void>) {
  if (snapshotBusy) return;
  snapshotBusy = true;
  renderSnapshots();
  renderHistory();
  renderRetention(true);
  try {
    await action();
  } catch (error) {
    logger.error('[HISTORY]', 'snapshot action failed', error);
    showToast(_('Could not load data'), 'error');
  } finally {
    snapshotBusy = false;
    await loadAll();
  }
}

async function restoreSnapshot(id: string, label: string) {
  // UC-068: unsaved changes of this session would be merged into the
  // restored configuration by a later Save & Apply.
  const sessionChanges = await Promise.resolve(uci.changes?.()).catch(
    () => null,
  );
  if (unsavedChangesBlockRestore(sessionChanges, PROKOP_UCI_PACKAGE)) {
    showToast(unsavedChangesText(), 'warning', 8000);
    return;
  }

  const diff = await loadDiff(id);

  // Whether Prokop is stopped by the user or not started since boot now
  // decides what the restore does (D-15).
  await refreshRuntimeUiState({ force: true }).catch(() => undefined);
  const services = store.get().servicesInfoWidget.data;
  const staysStopped = Boolean(
    services.prokopStoppedByUser || services.prokopNotStarted,
  );

  // D-16: a snapshot of an older release is migrated before the restore.
  const migrationNote = restoreMigrationNote(
    snapshots?.find((snapshot) => snapshot.id === id)?.migration,
  );
  const confirmed = await confirmAction({
    title: _('Restore configuration snapshot?'),
    message: `${label}. ${restoreConfirmMessage(staysStopped)}`,
    consequences: diff
      ? diff.total
        ? restorePreview(diff, MAX_RESTORE_PREVIEW)
        : [_('No saved changes since this snapshot')]
      : [_('Could not compare configurations')],
    notes: migrationNote ? [migrationNote] : [],
    confirmLabel: _('Restore'),
    danger: true,
  });
  if (!confirmed) return;

  await runSnapshotAction(async () => {
    const result = await ProkopShellMethods.snapshotRestore(id);
    const toast = restoreResultToast(result.success ? result.data : undefined);
    showToast(toast.text, toast.type, toast.duration);
  });
}

async function deleteSnapshot(id: string, label: string) {
  const confirmed = await confirmAction({
    title: _('Delete snapshot?'),
    message: `${label}. ${_('Delete this configuration snapshot?')}`,
    confirmLabel: _('Delete'),
    danger: true,
  });
  if (!confirmed) return;

  await runSnapshotAction(async () => {
    const result = await ProkopShellMethods.snapshotDelete(id);
    const toast = deleteSnapshotToast(result.success ? result.data : undefined);
    showToast(toast.text, toast.type, toast.duration);
  });
}

async function clearSnapshots() {
  const removable = removableSnapshots(snapshots ?? []).length;
  const confirmed = await confirmAction({
    title: _('Delete automatic snapshots?'),
    message: _(
      'Automatic snapshots that nothing protects are deleted: %d now.',
    ).replace('%d', String(removable)),
    consequences: [
      _('Manual snapshots are kept.'),
      _(
        'The last known good snapshot, the one an autotune change can still roll back to, the one of an unapplied change and those an unfinished restore needs are kept.',
      ),
    ],
    confirmLabel: _('Delete'),
    danger: true,
  });
  if (!confirmed) return;

  await runSnapshotAction(async () => {
    const result = await ProkopShellMethods.snapshotClear();
    const toast = clearSnapshotsToast(result.success ? result.data : undefined);
    showToast(toast.text, toast.type, toast.duration);
  });
}

async function clearHistory() {
  const confirmed = await confirmAction({
    title: _('Clear history?'),
    message: _(
      'All history records are deleted; the history then shows one record, that it was cleared.',
    ),
    consequences: [
      _(
        'Snapshots and the recovery state are not changed: a failed change still asks for recovery.',
      ),
    ],
    confirmLabel: _('Clear'),
    danger: true,
  });
  if (!confirmed) return;

  await runSnapshotAction(async () => {
    const result = await ProkopShellMethods.historyClear();
    const toast = clearHistoryToast(result.success ? result.data : undefined);
    showToast(toast.text, toast.type, toast.duration);
  });
}

function currentRetention(): Prokop.HistoryRetention {
  return history?.retention ?? DEFAULT_RETENTION;
}

async function saveRetention() {
  const draft = retentionDraft;
  if (!draft) return;
  const input = parseRetentionInput(draft.history, draft.snapshots);
  if (!input.ok) {
    retentionError = input.message;
    renderRetention(true);
    return;
  }
  retentionError = '';
  const consequences = retentionConsequences(
    input,
    currentRetention(),
    snapshots,
    history?.events.length ?? 0,
  );
  if (consequences.length) {
    const confirmed = await confirmAction({
      title: _('Lower the retention limits?'),
      message: _('The new limits apply at once.'),
      consequences,
      confirmLabel: _('Save'),
      danger: true,
    });
    if (!confirmed) return;
  }

  await runSnapshotAction(async () => {
    const result = await ProkopShellMethods.historyRetentionSet(
      input.history,
      input.snapshots,
    );
    const data = result.success ? result.data : undefined;
    if (data?.status === 'saved') retentionDraft = null;
    const toast = retentionToast(data);
    showToast(toast.text, toast.type, toast.duration);
  });
}

// force: also while one of its fields has focus (a refresh leaves a field
// the user is typing in alone).
function renderRetention(force = false) {
  const container = document.getElementById('history-retention');
  if (
    !force &&
    container &&
    container.contains(document.activeElement) &&
    document.activeElement?.tagName === 'INPUT'
  )
    return;

  if (historyFailed || !history) {
    replace(
      'history-retention',
      historyFailed
        ? renderErrorState(_('History is unavailable'), () => void loadAll())
        : renderLoadingState(),
    );
    return;
  }

  const limits = currentRetention();
  const manual = snapshots?.filter((s) => s.kind === 'manual').length;
  const usage = E('dl', { class: 'fkp-history__facts' }, [
    E('dt', {}, _('History records')),
    E(
      'dd',
      {},
      _('%d of %d')
        .replace('%d', String(history.events.length))
        .replace('%d', String(limits.history_limit)),
    ),
    E('dt', {}, _('Snapshots')),
    E(
      'dd',
      {},
      snapshots
        ? _('%d of %d, manual %d of %d')
            .replace('%d', String(snapshots.length))
            .replace('%d', String(limits.snapshot_limit))
            .replace('%d', String(manual))
            .replace('%d', String(limits.manual_snapshot_limit))
        : _('Unknown'),
    ),
  ]);

  if (isReadonlyMode()) {
    replace('history-retention', usage);
    return;
  }

  const draft = retentionDraft ?? {
    history: String(limits.history_limit),
    snapshots: String(limits.snapshot_limit),
  };
  const field = (
    id: string,
    label: string,
    value: string,
    bounds: { min: number; max: number },
    onInput: (value: string) => void,
  ) => {
    const input = E('input', {
      id,
      class: 'cbi-input-text',
      type: 'number',
      min: String(bounds.min),
      max: String(bounds.max),
      step: '1',
      value,
    }) as HTMLInputElement;
    input.oninput = () => onInput(input.value);
    return E('label', { class: 'fkp-history__field' }, [
      E('span', {}, asText(label)),
      input,
    ]);
  };
  const update = (patch: Partial<{ history: string; snapshots: string }>) => {
    retentionDraft = { ...draft, ...retentionDraft, ...patch };
    // An error said about the previous value goes once the user edits it.
    if (retentionError) {
      retentionError = '';
      document
        .querySelector('#history-retention .fkp-history__error')
        ?.remove();
    }
  };

  replace(
    'history-retention',
    usage,
    E('div', { class: 'fkp-history__retention' }, [
      field(
        'history-retention-history',
        _('Keep history records'),
        draft.history,
        RETENTION_BOUNDS.history,
        (value) => update({ history: value }),
      ),
      field(
        'history-retention-snapshots',
        _('Keep snapshots'),
        draft.snapshots,
        RETENTION_BOUNDS.snapshots,
        (value) => update({ snapshots: value }),
      ),
      E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button cbi-button-save',
          disabled: snapshotBusy ? true : undefined,
          click: () => void saveRetention(),
        },
        _('Save'),
      ),
    ]),
    E(
      'p',
      { class: 'fkp-history__hint' },
      _(
        'History: %d to %d records. Snapshots: %d to %d, two places of them stay for the automatic snapshots taken before a restore, Save & Apply or autotune. Older records and automatic snapshots beyond the limits are deleted automatically; manual and protected snapshots are never deleted automatically.',
      )
        .replace('%d', String(RETENTION_BOUNDS.history.min))
        .replace('%d', String(RETENTION_BOUNDS.history.max))
        .replace('%d', String(RETENTION_BOUNDS.snapshots.min))
        .replace('%d', String(RETENTION_BOUNDS.snapshots.max)),
    ),
    ...(retentionError
      ? [
          E(
            'p',
            { class: 'fkp-history__error', role: 'alert' },
            asText(retentionError),
          ),
        ]
      : []),
  );
}

async function createSnapshot() {
  await runSnapshotAction(async () => {
    const result = await ProkopShellMethods.snapshotCreate('manual');
    const toast = createSnapshotToast(result.success ? result.data : undefined);
    showToast(toast.text, toast.type, toast.duration);
  });
}

function renderSnapshots() {
  const readonly = isReadonlyMode();
  replace(
    'history-snapshot-actions',
    ...(readonly
      ? []
      : [
          E(
            'button',
            {
              type: 'button',
              class: 'btn cbi-button',
              disabled: snapshotBusy ? true : undefined,
              click: () => void createSnapshot(),
            },
            _('Create snapshot'),
          ),
          E(
            'button',
            {
              type: 'button',
              class: 'btn cbi-button',
              disabled:
                snapshotBusy || !removableSnapshots(snapshots ?? []).length
                  ? true
                  : undefined,
              title: removableSnapshots(snapshots ?? []).length
                ? undefined
                : _(
                    'Nothing to delete: only manual and protected snapshots are left.',
                  ),
              click: () => void clearSnapshots(),
            },
            _('Clear…'),
          ),
        ]),
  );

  if (snapshotsFailed || !snapshots) {
    replace(
      'history-snapshots',
      snapshotsFailed
        ? renderErrorState(
            _('Could not load configuration snapshots'),
            () => void loadAll(),
          )
        : renderLoadingState(),
    );
    return;
  }

  const rows = snapshotRows(snapshots);
  const shownRows = snapshotsExpanded
    ? rows
    : rows.slice(0, SNAPSHOTS_COLLAPSED);
  replace(
    'history-snapshots',
    rows.length
      ? E(
          'ul',
          { class: 'fkp-history__list' },
          shownRows.map((row) => {
            const label = row.reason ? `${row.time} · ${row.reason}` : row.time;
            return E('li', { class: 'fkp-history__snapshot' }, [
              E('span', { class: 'fkp-history__what' }, [
                label,
                ...(row.lkg
                  ? [
                      ' ',
                      E(
                        'span',
                        { class: 'fkp-history__lkg' },
                        _('Last known good'),
                      ),
                    ]
                  : []),
              ]),
              E('span', { class: 'fkp-actions' }, [
                E(
                  'button',
                  {
                    type: 'button',
                    class: 'btn cbi-button',
                    click: () => void showChanges(row.id),
                  },
                  _('Changes'),
                ),
                ...(readonly
                  ? []
                  : [
                      renderOverflowMenu(_('Snapshot actions'), [
                        {
                          label: _('Restore…'),
                          onClick: () => void restoreSnapshot(row.id, label),
                          disabled: snapshotBusy,
                          danger: true,
                        },
                        {
                          label: row.canDelete
                            ? _('Delete…')
                            : row.protectedText,
                          onClick: () => void deleteSnapshot(row.id, label),
                          disabled: snapshotBusy || !row.canDelete,
                          danger: row.canDelete,
                        },
                      ]),
                    ]),
              ]),
            ]);
          }),
        )
      : renderEmptyState(_('No snapshots yet')),
    ...(rows.length > SNAPSHOTS_COLLAPSED
      ? [
          E('div', { class: 'fkp-history__more' }, [
            E(
              'span',
              { class: 'fkp-history__hint' },
              _('Shown %d of %d')
                .replace('%d', String(shownRows.length))
                .replace('%d', String(rows.length)),
            ),
            E(
              'button',
              {
                type: 'button',
                class: 'btn cbi-button',
                click: () => {
                  snapshotsExpanded = !snapshotsExpanded;
                  renderSnapshots();
                },
              },
              snapshotsExpanded ? _('Show fewer') : _('Show all'),
            ),
          ]),
        ]
      : []),
  );
}

function renderAll() {
  renderState();
  renderHistory();
  renderSnapshots();
  renderRetention();
}

function onPageMount() {
  onPageUnmount();
  mounted = true;
  mountId += 1;
  historyShown = HISTORY_PAGE_SIZE;
  snapshotsExpanded = false;
  retentionDraft = null;
  retentionError = '';
  renderAll();
  void loadAll();
  refreshTimer = setInterval(() => {
    if (!snapshotBusy && !isPageHidden()) void loadAll();
  }, REFRESH_INTERVAL_MS);
}

function onPageUnmount() {
  mounted = false;
  mountId += 1;
  if (refreshTimer) clearInterval(refreshTimer);
  refreshTimer = null;
}

let initialized = false;

export async function initController(): Promise<void> {
  if (initialized) return;
  initialized = true;

  onMount('history-status').then(() => {
    store.subscribe(
      (next: StoreType, prev: StoreType, diff: Partial<StoreType>) => {
        if (
          diff.tabService &&
          next.tabService.current !== prev.tabService.current
        ) {
          if (next.tabService.current === 'history') onPageMount();
          else onPageUnmount();
        }
      },
    );
    if (
      store.get().tabService.current === 'history' ||
      isActiveLuciTab('history')
    ) {
      onPageMount();
    }
  });
}
