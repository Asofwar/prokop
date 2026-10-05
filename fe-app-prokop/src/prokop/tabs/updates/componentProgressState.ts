import type { Prokop } from '../../types';

// The part of a component's progress the shared store keeps (get_ui_state,
// uiState.service.ts) and the cards are keyed by. Rendering it lives in
// componentProgress.ts, a LuCI module of its own (component_progress.js) that
// only the page with the component cards loads.

type Stage = Prokop.ComponentActionStage;

const STAGES: Stage[] = [
  'resolve',
  'lists',
  'download',
  'verify',
  'backup',
  'prepare',
  'stop',
  'install',
  'remove',
  'apply',
  'start',
  'restart',
  'check',
  'rollback',
];

function isStage(value: unknown): value is Stage {
  return typeof value === 'string' && STAGES.includes(value as Stage);
}

function nonNegative(value: unknown) {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0
    ? Math.trunc(value)
    : null;
}

// Known fields of the right type only: the file is read straight from the
// router, an older or newer release may write more or less.
export function normalizeProgress(
  raw: unknown,
): Prokop.ComponentActionProgress | null {
  if (!raw || typeof raw !== 'object') {
    return null;
  }

  const value = raw as Record<string, unknown>;
  const stages = Array.isArray(value.stages)
    ? value.stages.flatMap((item) => {
        if (!item || typeof item !== 'object') {
          return [];
        }
        const stage = item as Record<string, unknown>;
        const startedAt = nonNegative(stage.started_at);
        if (!isStage(stage.id) || startedAt === null) {
          return [];
        }
        return [
          {
            id: stage.id,
            started_at: startedAt,
            finished_at: nonNegative(stage.finished_at),
          },
        ];
      })
    : [];
  const rawDownload =
    value.download && typeof value.download === 'object'
      ? (value.download as Record<string, unknown>)
      : null;

  return {
    stage: isStage(value.stage) ? value.stage : '',
    stages,
    download: rawDownload
      ? {
          file: typeof rawDownload.file === 'string' ? rawDownload.file : '',
          bytes: nonNegative(rawDownload.bytes) ?? 0,
          total: nonNegative(rawDownload.total) ?? 0,
          index: nonNegative(rawDownload.index) ?? 0,
          count: nonNegative(rawDownload.count) ?? 0,
        }
      : null,
    outcome:
      value.outcome === 'done' || value.outcome === 'failed'
        ? value.outcome
        : '',
    started_at: nonNegative(value.started_at),
    updated_at: nonNegative(value.updated_at),
  };
}

// The view a card shows. A card can carry the actions of another component
// (TorrServer's direct routing): a running action comes first, its own or
// the other's, then its own last result, then the other's (PRG-3).
export function cardProgressView(
  progress: Partial<
    Record<Prokop.ComponentName, Prokop.ComponentProgressView | undefined>
  >,
  component: Prokop.ComponentName,
  others: Prokop.ComponentName[] = [],
) {
  const views = [component, ...others]
    .map((name) => progress[name])
    .filter((view): view is Prokop.ComponentProgressView => Boolean(view));

  return views.find((view) => view.running) || views[0] || null;
}

// What decides the shape of a card around its progress: which action it
// shows and whether that one runs.
export function progressViewKey(view: Prokop.ComponentProgressView | null) {
  return view ? `${view.component}:${view.jobId}:${view.running}` : '';
}
