import { Prokop } from '../../types';
import {
  eventKindLabel,
  eventOutcomeView,
  toEventOutcome,
  type StatusTone,
} from '../../ui/status';
import { formatDateTime, formatRelativeTime } from '../../ui/time';

// Pure view model of the History & Recovery page.

export interface RecoveryRow {
  label: string;
  value: string;
  tone: StatusTone;
}

// A plain reload is not a recovery: only restores (an autotune rollback
// restores a snapshot too) and events that ended in a rollback
// ("recovered") count. diagnostics/health.uc never recorded a 'recovery'
// event kind; one would read as an other event.
export function lastRecoveryEvent(health: Prokop.HealthStatus) {
  const events = [
    ...health.recent_activity,
    ...(health.recovery.last_event ? [health.recovery.last_event] : []),
  ].filter(
    (event) =>
      event.kind === 'restore' ||
      event.kind === 'autotune_rollback' ||
      event.status === 'recovered',
  );
  return events.sort((a, b) => b.timestamp - a.timestamp)[0] ?? null;
}

function eventText(event: { kind: string; status: string; timestamp: number }) {
  const outcome = eventOutcomeView(toEventOutcome(event.status));
  return {
    value: `${eventKindLabel(event.kind)}: ${outcome.label} · ${formatDateTime(event.timestamp)}`,
    tone: outcome.tone,
  };
}

// The DPI guard by what ends it (diagnostics/health.uc recovery.action):
// only one that a change still holds is transient (UC-019, UC-066).
function guardRow(health: Prokop.HealthStatus) {
  if (!health.guard.active)
    return { value: _('Inactive'), tone: 'success' as const };
  switch (health.recovery.action) {
    case 'wait':
      return {
        value: _('Active: a change is being applied'),
        tone: 'loading' as const,
      };
    case 'restart':
      return {
        value: _('Active: kept by a failed change'),
        tone: 'error' as const,
      };
    case 'restore':
      return {
        value: _('Active: restore not finished'),
        tone: 'error' as const,
      };
    default:
      return {
        value: _('Active: DPI switch not confirmed'),
        tone: 'error' as const,
      };
  }
}

// recovery.pending means a guard is left or the last event failed: neither
// is in progress unless a change still holds its guard. A failed last event
// is named, with the previous configuration kept (UC-066).
function lastRecoveryRow(health: Prokop.HealthStatus) {
  if (health.guard.active)
    return health.recovery.action === 'wait'
      ? { value: _('In progress'), tone: 'loading' as const }
      : { value: _('Needs attention'), tone: 'error' as const };
  const failed = health.recovery.last_event;
  if (failed) return eventText(failed);
  return { value: _('Needs attention'), tone: 'error' as const };
}

// The step that ends a DPI guard that is left; none while a change holds it.
function nextStepRow(health: Prokop.HealthStatus): RecoveryRow[] {
  if (!health.guard.active) return [];
  switch (health.recovery.action) {
    case 'restart':
      return [
        {
          label: _('Next step'),
          value: _(
            'Restart Prokop: the restart removes the DPI guard that a failed change left in place.',
          ),
          tone: 'warning',
        },
      ];
    case 'restore':
      return [
        {
          label: _('Next step'),
          value: _(
            'Restore the last known good snapshot: the restore finishes and removes the DPI guard.',
          ),
          tone: 'warning',
        },
      ];
    default:
      return [];
  }
}

export function recoveryRows(
  health: Prokop.HealthStatus,
  snapshots: Prokop.SnapshotMetadata[] | null,
): RecoveryRow[] {
  const last = lastRecoveryEvent(health);
  const reload = health.last_reload;
  const lkg = snapshots?.find((snapshot) => snapshot.is_lkg);
  const reloadOutcome = reload
    ? eventOutcomeView(toEventOutcome(reload.status))
    : null;

  return [
    {
      label: _('DPI guard'),
      ...guardRow(health),
    },
    {
      label: _('Last recovery'),
      ...(health.recovery.pending
        ? lastRecoveryRow(health)
        : last
          ? eventText(last)
          : { value: _('Not needed'), tone: 'success' as const }),
    },
    ...nextStepRow(health),
    {
      label: _('Package recovery'),
      ...(health.package_recovery.pending
        ? { value: _('Waiting to finish'), tone: 'warning' as const }
        : { value: _('Not needed'), tone: 'success' as const }),
    },
    {
      label: _('Last reload'),
      ...(reload && reloadOutcome
        ? {
            value: `${reloadOutcome.label} · ${formatDateTime(reload.timestamp)}`,
            tone: reloadOutcome.tone,
          }
        : { value: _('No reload recorded yet'), tone: 'neutral' as const }),
    },
    {
      label: _('Last known good configuration'),
      ...(lkg
        ? { value: formatDateTime(lkg.created_at), tone: 'success' as const }
        : snapshots
          ? { value: _('Not recorded yet'), tone: 'neutral' as const }
          : { value: _('Unknown'), tone: 'neutral' as const }),
    },
  ];
}

export type HistoryFilter = 'all' | 'config' | 'service' | 'autotune';

const CATEGORY: Record<string, Exclude<HistoryFilter, 'all'>> = {
  reload: 'config',
  restore: 'config',
  snapshot_create: 'config',
  snapshot_delete: 'config',
  start: 'service',
  recovery: 'service',
  cron_refresh: 'service',
  config_migration: 'config',
  autotune_apply: 'autotune',
  autotune_rollback: 'autotune',
  autotune_mode: 'autotune',
  autotune_recommendation: 'autotune',
  autotune_run: 'autotune',
};

export function historyFilterLabel(filter: HistoryFilter) {
  switch (filter) {
    case 'config':
      return _('Configuration');
    case 'service':
      return _('Service');
    case 'autotune':
      return _('Autotune');
    default:
      return _('All');
  }
}

export interface HistoryItem {
  title: string;
  outcome: { label: string; tone: StatusTone };
  time: string;
  relative: string;
  // What the event changed, one line each (config_migration notices).
  details: string[];
}

// A notice of a configuration migration, in words. A rule is named by its
// UCI section name: the journal does not keep labels.
export function migrationNoticeText(notice: Prokop.MigrationNotice) {
  switch (notice.code) {
    case 'retired_rule_sets': {
      const removed = _(
        'Rule “%s”: the retired rule sets %s were removed from Built-in rule sets #2, their source no longer publishes them.',
      )
        .replace('%s', notice.section)
        .replace('%s', notice.values.join(', '));
      return notice.replacements.length
        ? `${removed} ${_(
            'Built-in rule sets of the same services: %s. They were not added; the rule editor offers them.',
          ).replace('%s', notice.replacements.join(', '))}`
        : `${removed} ${_('No built-in rule set replaces them.')}`;
    }
    case 'subscription_options_removed':
      return _(
        'Rule “%s”: the subscription settings %s were removed. This version always generates the HWID from the router and hides nodes of imported URLTest groups and cascades.',
      )
        .replace('%s', notice.section)
        .replace('%s', notice.values.join(', '));
    // The User-Agent itself is not in the journal (D-17).
    case 'subscription_user_agent_in_effect':
      return _(
        'Rule “%s”: a subscription source now sends the User-Agent set in its settings. Earlier versions ignored it and chose one automatically; clear the field to go back to automatic selection.',
      ).replace('%s', notice.section);
    case 'update_interval_raised':
      return (
        notice.values[0] === 'component_update_check_interval'
          ? _(
              'Component update check interval was %s, shorter than the 1 h minimum of automatic updates: set to %s.',
            )
          : _(
              'List update frequency was %s, shorter than the 1 h minimum of automatic updates: set to %s.',
            )
      )
        .replace('%s', notice.from ?? '')
        .replace('%s', notice.to ?? '');
    default:
      return _('Rule “%s”: changed by the update.').replace(
        '%s',
        notice.section,
      );
  }
}

// An autotune apply or rollback names its strategy and whether a person or
// the schedule (for a rollback: a failed verification) started it; other
// events are named by their kind.
export function eventTitle(event: Prokop.HistoryEvent) {
  if (event.kind === 'autotune_rollback' && event.trigger)
    return rollbackTitle(event.trigger === 'manual', event.candidate ?? '');
  if (event.kind !== 'autotune_apply' || !event.trigger)
    return eventKindLabel(event.kind);
  const candidate = event.candidate ?? '';
  const manual = event.trigger === 'manual';
  if (!candidate)
    return manual
      ? _('Autotune: manual apply')
      : _('Autotune: automatic apply');
  if (event.status === 'success')
    return (
      manual
        ? _('Autotune: %s applied manually')
        : _('Autotune: %s applied automatically')
    ).replace('%s', candidate);
  return (
    manual
      ? _('Autotune: manual apply of %s')
      : _('Autotune: automatic apply of %s')
  ).replace('%s', candidate);
}

function rollbackTitle(manual: boolean, candidate: string) {
  if (!candidate)
    return manual
      ? _('Autotune: manual rollback')
      : _('Autotune: automatic rollback');
  return (
    manual
      ? _('Autotune: manual rollback of %s')
      : _('Autotune: automatic rollback of %s')
  ).replace('%s', candidate);
}

// Newest first.
export function historyItems(
  events: Prokop.HistoryEvent[],
  filter: HistoryFilter,
  nowMs = Date.now(),
): HistoryItem[] {
  // Newest first; of events in the same second (the journal's only clock),
  // the one recorded later: an automatic autotune rollback is recorded
  // before the apply that it ended, whatever second each falls in.
  return events
    .map((event, index) => ({ event, index }))
    .filter(({ event }) => filter === 'all' || CATEGORY[event.kind] === filter)
    .sort((a, b) => b.event.timestamp - a.event.timestamp || b.index - a.index)
    .map(({ event }) => ({
      title: eventTitle(event),
      outcome: eventOutcomeView(toEventOutcome(event.status)),
      time: formatDateTime(event.timestamp),
      relative: formatRelativeTime(event.timestamp, nowMs),
      details: (event.notices ?? []).map(migrationNoticeText),
    }));
}

export function snapshotReasonLabel(reason: string) {
  switch (reason) {
    case 'manual':
      return _('Manual');
    // Taken when a reload starts, after the change was committed: the
    // configuration the reload applies, possibly the one that failed
    // (UC-067).
    case 'before-reload':
      return _('Applied by reload');
    // Save & Apply's snapshot of the configuration before the change.
    case 'before-apply':
      return _('Before applying changes');
    case 'pre-restore':
      return _('Before restore');
    case 'last-known-working':
      return _('Last known good');
    case 'before-autotune':
      return _('Before autotune');
    // A configuration edited while a restore or an autotune change owned it:
    // kept, never rolled back or taken for the restored one
    // (config/snapshots.uc).
    case 'concurrent-change':
      return _('Concurrent edit');
    default:
      return _('Other');
  }
}

// Why a snapshot cannot be deleted, as the menu and the refusal say it.
export function protectedSnapshotText(reason: string | undefined) {
  switch (reason) {
    case 'lkg_protected':
      return _('The last known good snapshot cannot be deleted');
    case 'autotune_rollback_protected':
      return _(
        'This snapshot cannot be deleted while the autotune change can still be rolled back to it',
      );
    case 'apply_snapshot_protected':
      return _(
        'This snapshot cannot be deleted until the saved change has been applied',
      );
    default:
      return '';
  }
}

// Newest first; protected snapshots (last known good, autotune rollback,
// Save & Apply) cannot be deleted.
export function snapshotRows(snapshots: Prokop.SnapshotMetadata[]) {
  return snapshots
    .slice()
    .sort((a, b) => b.created_at - a.created_at)
    .map((snapshot) => ({
      id: snapshot.id,
      time: formatDateTime(snapshot.created_at),
      // The badge already says "last known good" for such snapshots.
      reason:
        snapshot.is_lkg && snapshot.reason === 'last-known-working'
          ? ''
          : snapshotReasonLabel(snapshot.reason),
      lkg: Boolean(snapshot.is_lkg),
      canDelete: !snapshot.is_lkg && !snapshot.protected_reason,
      protectedText: protectedSnapshotText(
        snapshot.protected_reason ??
          (snapshot.is_lkg ? 'lkg_protected' : undefined),
      ),
    }));
}

// null: the option is not set on that side, not a hidden value (D-2).
function diffValue(value: string | string[] | null | undefined) {
  if (value === null || value === undefined) return _('not set');
  if (Array.isArray(value)) return value.length ? value.join(', ') : '—';
  return value === '' ? '—' : value;
}

// `before` is the snapshot value, `after` the saved configuration now.
export function diffRows(changes: Prokop.SnapshotChange[]) {
  return changes.map((change) => ({
    where: `${change.section} · ${change.option}`,
    snapshot: diffValue(change.before),
    current: diffValue(change.after),
  }));
}

export interface SnapshotDiff {
  changes: Prokop.SnapshotChange[];
  // Every changed option: more than `changes` when the list is cut.
  total: number;
}

function isTruncation(
  entry: Prokop.SnapshotDiffEntry,
): entry is Prokop.SnapshotDiffTruncation {
  return (entry as Prokop.SnapshotDiffTruncation).truncated === true;
}

// UC-062: the backend lists a limited number of changes; a longer diff ends
// with { truncated, total } in place of the rest.
export function snapshotDiff(
  entries: Prokop.SnapshotDiffEntry[],
): SnapshotDiff {
  const changes = entries.filter(
    (entry): entry is Prokop.SnapshotChange => !isTruncation(entry),
  );
  const marker = entries.find(isTruncation);
  return {
    changes,
    total: Math.max(Number(marker?.total) || 0, changes.length),
  };
}

// Above a cut list in the Changes modal: the list is not the whole change.
export function diffTruncatedText(diff: SnapshotDiff) {
  return _('Only the first %d changes are listed; %d changes in total.')
    .replace('%d', String(diff.changes.length))
    .replace('%d', String(diff.total));
}

// The restore confirmation: the first `limit` changes, then how many more
// the restore changes, counted of all of them, not of the listed ones
// (UC-062).
export function restorePreview(diff: SnapshotDiff, limit: number) {
  const preview = diffRows(diff.changes.slice(0, limit)).map(
    (row) => `${row.where}: ${row.current} → ${row.snapshot}`,
  );
  const more = diff.total - preview.length;
  if (more > 0) preview.push(_('and %d more').replace('%d', String(more)));
  return preview;
}

export interface SnapshotToast {
  text: string;
  type: 'success' | 'warning' | 'error';
  duration: number;
}

// A snapshot operation refused before it changed anything. A reload that is
// only queued, with no live service action, never refuses a restore: the
// restore's own reload runs it.
export function snapshotBusyText(reason?: string) {
  if (reason === 'service_action_in_progress')
    return _(
      'The service is busy with another operation (list or subscription update, reload or start). Nothing was changed; try again when it finishes.',
    );
  return _(
    'Another snapshot operation is already in progress. Try again in a moment.',
  );
}

// Manual snapshots stop two short of the snapshot store's size
// (config/snapshots.uc MANUAL_LIMIT, D-14): the two places stay for the
// automatic snapshots a restore, Save & Apply and autotune take. The backend
// names its limit with the refusal; this only stands in for a missing one.
const MANUAL_SNAPSHOT_LIMIT = 8;

// What "Delete" did. A refusal says why (UC-119): the last known good
// snapshot is never deleted, and one that is gone or unreadable cannot be.
export function deleteSnapshotToast(
  result: Pick<Prokop.SnapshotResult, 'status' | 'reason'> | undefined,
): SnapshotToast {
  if (result?.status === 'deleted')
    return { text: _('Snapshot deleted'), type: 'success', duration: 3000 };
  if (result?.status === 'busy')
    return {
      text: snapshotBusyText(result.reason),
      type: 'warning',
      duration: 6000,
    };
  if (result?.reason === 'lkg_protected')
    return {
      text: _(
        'The last known good snapshot cannot be deleted: it is the configuration Prokop returns to after a failed change.',
      ),
      type: 'warning',
      duration: 8000,
    };
  if (
    result?.reason === 'autotune_rollback_protected' ||
    result?.reason === 'apply_snapshot_protected'
  )
    return {
      text: `${protectedSnapshotText(result.reason)}.`,
      type: 'warning',
      duration: 8000,
    };
  if (result?.reason === 'invalid_snapshot')
    return {
      text: _('The snapshot was not found or cannot be read.'),
      type: 'error',
      duration: 6000,
    };
  return {
    text: _('Could not delete snapshot'),
    type: 'error',
    duration: 3000,
  };
}

// What "Create snapshot" did. A refusal says why and what to do, never only
// that the snapshot could not be created (UC-022).
export function createSnapshotToast(
  result: Prokop.SnapshotResult | undefined,
): SnapshotToast {
  switch (result?.status) {
    case 'created':
      return { text: _('Snapshot saved'), type: 'success', duration: 3000 };
    case 'busy':
      return {
        text: snapshotBusyText(result.reason),
        type: 'warning',
        duration: 6000,
      };
    case 'failed':
      switch (result.reason) {
        // Nothing removes a manual snapshot to make room: the user does.
        // More than one has to go while more are left from before the
        // limit (an upgrade): the toast says how many.
        case 'manual_limit_reached': {
          const limit = result.limit ?? MANUAL_SNAPSHOT_LIMIT;
          const excess = (result.manual ?? limit) - limit + 1;
          return {
            text:
              excess > 1
                ? _(
                    'Snapshot not saved: at most %d manual snapshots are kept, so that the automatic snapshots taken before a restore, Save & Apply or autotune always have room. There are %d manual snapshots now: delete %d you no longer need, then try again.',
                  )
                    .replace('%d', String(limit))
                    .replace('%d', String(result.manual))
                    .replace('%d', String(excess))
                : _(
                    'Snapshot not saved: at most %d manual snapshots are kept, so that the automatic snapshots taken before a restore, Save & Apply or autotune always have room. Delete a manual snapshot you no longer need, then try again.',
                  ).replace('%d', String(limit)),
            type: 'warning',
            duration: 12000,
          };
        }
        case 'config_unavailable':
          return {
            text: _(
              'Snapshot not saved: the configuration file could not be read.',
            ),
            type: 'error',
            duration: 8000,
          };
        case 'hash_unavailable':
        case 'write_failed':
          return {
            text: _(
              'Snapshot not saved: it could not be written. Check the free space on the router.',
            ),
            type: 'error',
            duration: 8000,
          };
        case 'lock_unavailable':
          return {
            text: _(
              'Snapshot not saved: the snapshot storage could not be locked. Try again in a moment.',
            ),
            type: 'error',
            duration: 8000,
          };
      }
      break;
  }
  return {
    text: _('Could not create snapshot'),
    type: 'error',
    duration: 3000,
  };
}

// A restore refused before its transaction started: nothing was changed,
// and it is no restore event in the history (UC-022). null for a reason
// without a text of its own.
function restoreRefusalText(reason: string | undefined): string | null {
  switch (reason) {
    case 'pre_restore_snapshot_failed':
      return _(
        'Restore was not started: the current configuration could not be saved as a snapshot first. Nothing was changed. Check the free space on the router.',
      );
    case 'invalid_snapshot':
      return _(
        'Restore was not started: the snapshot is missing or damaged. Nothing was changed.',
      );
    case 'config_unavailable':
      return _(
        'Restore was not started: the current configuration could not be read. Nothing was changed.',
      );
    case 'concurrent_change':
      return _(
        'Restore was not started: the configuration was changed while the restore was starting. Nothing was changed; check the change and try again.',
      );
    case 'guard_unavailable':
      return _(
        'Restore was not started: the DPI guard that protects traffic during the restore could not be installed. Nothing was changed.',
      );
    case 'lock_unavailable':
      return _(
        'Restore was not started: the snapshot storage could not be locked. Nothing was changed.',
      );
    // D-16: a snapshot of an older release whose configuration cannot be
    // migrated to this one is never restored as it was saved.
    case 'snapshot_migration_failed':
      return _(
        'Restore was not started: the snapshot was saved by an older version of Prokop, and its configuration could not be migrated to this version. Nothing was changed.',
      );
    default:
      return null;
  }
}

// Changes of this LuCI session that are saved but not applied (rpcd keeps
// them per session). The restore's reload does not read them, but a later
// Save & Apply would merge them into the restored configuration: they are
// applied or reverted first. Unknown changes (the call failed) block nothing.
export function unsavedChangesBlockRestore(
  changes: Record<string, unknown> | null | undefined,
  uciPackage: string,
): boolean {
  const pending = changes?.[uciPackage];
  return Array.isArray(pending) && pending.length > 0;
}

export function unsavedChangesText() {
  return _(
    'There are unsaved changes of Prokop in this session. Save & Apply or revert them, then restore the snapshot.',
  );
}

// What the restore will do, said before the user confirms it. Prokop
// stopped by the user, or not started since boot, is not started by a
// restore (D-15): the configuration is replaced and checked, and takes
// effect at the next start.
export function restoreConfirmMessage(staysStopped: boolean): string {
  return staysStopped
    ? _(
        'Prokop is stopped: the configuration is replaced and checked, but Prokop is not started. It takes effect when you start Prokop.',
      )
    : _(
        'Prokop reloads the configuration. If the reload fails, the previous configuration is restored automatically.',
      );
}

// D-16: before a snapshot of an older release is restored, its
// configuration is migrated to the running release, as an upgrade migrates
// it; the snapshot file stays as it was. The changes listed in the
// confirmation compare the snapshot as it was saved. null: no migration.
export function restoreMigrationNote(
  migration: Prokop.SnapshotMigration | null | undefined,
): string | null {
  if (!migration) return null;
  return migration.from && migration.from !== 'unknown'
    ? _(
        'This snapshot was saved by Prokop %s. Before the restore, its configuration is migrated to the current version %s, as an upgrade migrates it: settings retired since then are updated. The snapshot itself is not changed; the changes listed above compare the snapshot as it was saved.',
      )
        .replace('%s', migration.from)
        .replace('%s', migration.to)
    : _(
        'This snapshot was saved by an older version of Prokop. Before the restore, its configuration is migrated to the current version %s, as an upgrade migrates it: settings retired since then are updated. The snapshot itself is not changed; the changes listed above compare the snapshot as it was saved.',
      ).replace('%s', migration.to);
}

// A restore that migrated the snapshot says so after its own text.
function withMigration(
  text: string,
  migration: Prokop.SnapshotMigration | undefined,
): string {
  if (!migration) return text;
  const migrated =
    migration.from && migration.from !== 'unknown'
      ? _(
          'The configuration of the snapshot was migrated from Prokop %s to %s.',
        )
          .replace('%s', migration.from)
          .replace('%s', migration.to)
      : _(
          'The configuration of the snapshot was migrated to Prokop %s.',
        ).replace('%s', migration.to);
  return `${text}${text.endsWith('.') ? '' : '.'} ${migrated}`;
}

// What a finished restore means. A reload that the service only queued
// behind another operation never ran, so it is never reported as restored.
export function restoreResultToast(
  result: Prokop.SnapshotResult | undefined,
): SnapshotToast {
  switch (result?.status) {
    case 'busy':
      return {
        text: snapshotBusyText(result.reason),
        type: 'warning',
        duration: 6000,
      };
    case 'success':
      return {
        text: withMigration(
          _('Configuration restored and reloaded'),
          result.migration,
        ),
        type: 'success',
        duration: result.migration ? 10000 : 6000,
      };
    // Prokop was stopped by the user: only a start brings it back.
    case 'restored_not_started':
      return {
        text: withMigration(
          _(
            'Configuration restored, but Prokop is stopped: it was not started or checked. The restored configuration takes effect when Prokop is started.',
          ),
          result.migration,
        ),
        type: 'warning',
        duration: 10000,
      };
    case 'recovered':
      return {
        text:
          result.reason === 'target_reload_queued'
            ? _(
                'Restore was not applied: the service was busy and only queued the reload. The previous configuration is kept.',
              )
            : _('Restore failed; previous configuration and runtime recovered'),
        type: 'warning',
        duration: 8000,
      };
    case 'failed':
      // A failed lifecycle transition kept its DPI guard: no reload runs
      // until a restart removes it, so nothing was changed (UC-019).
      if (result.reason === 'runtime_guard_active')
        return {
          text: _(
            'Restore was not started: a failed change left the DPI guard in place, and nothing can be reloaded until Prokop is restarted. Restart Prokop, then restore the snapshot if it is still needed.',
          ),
          type: 'warning',
          duration: 12000,
        };
      // Changes staged on the router with uci but not committed would ride
      // along the reload (UC-068): nothing was changed.
      if (result.reason === 'uncommitted_uci_changes')
        return {
          text: _(
            'Restore was not started: the router has uncommitted uci changes of Prokop (made with "uci set" without a commit). Commit or revert them, then restore again.',
          ),
          type: 'warning',
          duration: 10000,
        };
      // The configuration file could not be replaced: nothing was reloaded.
      // A guard an earlier restore left stays (an own guard is released).
      if (result.reason === 'replace_failed')
        return {
          text:
            result.guard === 'active'
              ? `${_('Restore was not applied: the configuration file could not be written. The previous configuration is kept.')} ${_('The DPI guard of an earlier restore stays active.')}`
              : _(
                  'Restore was not applied: the configuration file could not be written. The previous configuration is kept.',
                ),
          type: 'warning',
          duration: 10000,
        };
      {
        // A guard an earlier restore left stays (concurrent_change).
        const refusal = restoreRefusalText(result.reason);
        if (refusal)
          return {
            text:
              result.guard === 'active'
                ? `${refusal} ${_('The DPI guard of an earlier restore stays active.')}`
                : refusal,
            type: 'warning',
            duration: 10000,
          };
      }
      if (result.runtime === 'stopped')
        return {
          text:
            result.reason === 'target_invalid'
              ? _(
                  'Restore was not applied: the snapshot configuration did not pass validation. The previous configuration is kept; Prokop stays stopped.',
                )
              : _(
                  'Restore was not applied: Prokop was stopped during the restore. The previous configuration is kept.',
                ),
          type: 'warning',
          duration: 10000,
        };
      break;
    case 'needs_attention':
      // Someone saved the configuration while the snapshot was being
      // reloaded: the change was kept instead of rolled back, and never
      // taken for the restored snapshot (UC-023). A snapshot of it is named
      // only when one was saved (not with the snapshot list full).
      if (result.reason === 'config_changed_during_transaction') {
        const kept = result.saved_snapshot
          ? _('The change is kept and saved as a snapshot ("Concurrent edit").')
          : _(
              'The change is kept in the configuration, but no snapshot of it could be saved.',
            );
        return {
          text:
            // Prokop was stopped: the snapshot was not reloaded, no
            // guard is left.
            result.runtime === 'stopped'
              ? `${_('Restore was not applied: Prokop was stopped, and the configuration was changed during the restore.')} ${kept}`
              : // The reload ran, but it may have read the change.
                result.guard === 'inactive'
                ? `${_('Restore did not finish: the configuration was changed while the snapshot was being applied. Prokop was reloaded, but it is not known whether with the snapshot or with the change.')} ${kept} ${_('Restore the snapshot you need to finish.')}`
                : `${_('Restore did not finish: the configuration was changed while the snapshot was being applied.')} ${kept} ${_('The DPI guard stays active. Restore the snapshot you need to finish.')}`,
          type: 'error',
          duration: 12000,
        };
      }
      // The reload left, or met, a DPI guard that a failed transition kept:
      // the restore's own guard stays until a restore after the restart.
      if (result.reason === 'runtime_guard_active')
        return {
          text: _(
            'Restore did not finish: a failed change left the DPI guard in place, and the DPI guard stays active. Restart Prokop, then restore the snapshot again.',
          ),
          type: 'error',
          duration: 12000,
        };
      if (result.reason === 'rollback_reload_queued')
        return {
          text: _(
            'Restore did not finish: the service was busy and only queued the reload. The DPI guard stays active; restore again when the service is idle.',
          ),
          type: 'error',
          duration: 10000,
        };
      break;
  }
  return {
    text: _('Restore failed; check the recovery state before retrying'),
    type: 'error',
    duration: 8000,
  };
}
