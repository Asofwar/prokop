import { asText } from '../../../helpers/asText';
import { isPageHidden } from '../../../helpers/isPageHidden';
import { routerNowSeconds } from '../../helpers/routerClock';
import type { Prokop } from '../../types';

// What a component card shows while its action runs and after it ends:
// the stages the router reported, the bytes of the current download, and the
// time spent. Everything comes from the router (components/progress.uc);
// there is no estimate of the time left, only the stages still ahead.

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

export function stageLabel(stage: Stage | '') {
  switch (stage) {
    case 'resolve':
      return _('Checking the release');
    case 'lists':
      return _('Updating package lists');
    case 'download':
      return _('Downloading');
    case 'verify':
      return _('Verifying checksums');
    case 'backup':
      return _('Backing up the configuration');
    case 'prepare':
      return _('Preparing a rollback copy');
    case 'stop':
      return _('Stopping services');
    case 'install':
      return _('Installing');
    case 'remove':
      return _('Removing');
    case 'apply':
      return _('Applying');
    case 'start':
      return _('Starting');
    case 'restart':
      return _('Restarting Prokop');
    case 'check':
      return _('Checking that it works');
    case 'rollback':
      return _('Restoring after the failure');
    default:
      return _('In progress');
  }
}

// The stages an action usually goes through, in order. Some are skipped
// when there is nothing to do (no running Prokop to restart, nothing
// installed to stop); a finished action lists only the ones it went
// through.
export function plannedStages(
  component: Prokop.ComponentName,
  action: Prokop.ComponentAction,
  installed = true,
): Stage[] {
  if (action === 'remove') {
    return ['zapret', 'zapret2', 'byedpi'].includes(component)
      ? ['remove', 'restart']
      : ['remove'];
  }

  if (
    action === 'enable' ||
    action === 'disable' ||
    action === 'restore' ||
    action === 'apply_settings'
  ) {
    return ['apply'];
  }

  if (action === 'start') {
    return ['start'];
  }

  switch (component) {
    case 'prokop':
      return [
        'resolve',
        'download',
        'verify',
        'prepare',
        'stop',
        'install',
        'restart',
        'check',
      ];
    case 'sing_box':
      return [
        'resolve',
        'download',
        'verify',
        'stop',
        'install',
        'restart',
        'check',
      ];
    case 'zapret':
    case 'zapret2':
    case 'byedpi':
      return ['resolve', 'lists', 'download', 'verify', 'install', 'restart'];
    case 'torrserver':
      return installed
        ? ['resolve', 'download', 'verify', 'stop', 'install', 'start']
        : ['resolve', 'download', 'verify', 'install', 'start'];
    case 'zapret_manager':
      return ['resolve', 'download', 'install'];
    default:
      return [];
  }
}

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

export function formatDuration(totalSeconds: number) {
  const seconds = Math.max(0, Math.floor(totalSeconds));

  if (seconds < 60) {
    return _('%s s').replace('%s', String(seconds));
  }

  if (seconds < 3600) {
    return _('%s min %s s')
      .replace('%s', String(Math.floor(seconds / 60)))
      .replace('%s', String(seconds % 60).padStart(2, '0'));
  }

  return _('%s h %s min')
    .replace('%s', String(Math.floor(seconds / 3600)))
    .replace('%s', String(Math.floor((seconds % 3600) / 60)).padStart(2, '0'));
}

export function formatBytes(bytes: number) {
  if (bytes < 1024) {
    return _('%s B').replace('%s', String(bytes));
  }

  if (bytes < 1024 * 1024) {
    return _('%s KB').replace('%s', (bytes / 1024).toFixed(1));
  }

  return _('%s MB').replace('%s', (bytes / (1024 * 1024)).toFixed(1));
}

export function downloadText(
  download: NonNullable<Prokop.ComponentActionProgress['download']>,
) {
  const parts: string[] = [];

  if (download.file) {
    parts.push(download.file);
  }

  if (download.count > 1 && download.index > 0) {
    parts.push(
      _('file %s of %s')
        .replace('%s', String(download.index))
        .replace('%s', String(download.count)),
    );
  }

  const head = parts.join(', ');
  let amount: string;

  if (download.total > 0) {
    const percent = Math.min(
      100,
      Math.floor((download.bytes / download.total) * 100),
    );
    amount = _('%s of %s (%s%)')
      .replace('%s', formatBytes(download.bytes))
      .replace('%s', formatBytes(download.total))
      .replace('%s', String(percent));
  } else {
    amount = _('%s received').replace('%s', formatBytes(download.bytes));
  }

  return head ? `${head}: ${amount}` : amount;
}

// The job's start: the worker's own record first, then the job state's.
export function viewStartedAt(view: Prokop.ComponentProgressView) {
  return view.progress?.started_at || view.startedAt || 0;
}

export function viewDuration(view: Prokop.ComponentProgressView) {
  const startedAt = viewStartedAt(view);

  if (!startedAt) {
    return null;
  }

  if (view.running) {
    return Math.max(0, routerNowSeconds() - startedAt);
  }

  const stages = view.progress?.stages || [];
  const lastEnd = stages.length ? stages[stages.length - 1].finished_at : null;
  const end = lastEnd || view.finishedAt || 0;

  return end >= startedAt ? end - startedAt : null;
}

// The stage a failed action failed at: the restore after the failure
// ('rollback') runs after it.
export function failedStageOf(view: Prokop.ComponentProgressView) {
  if (view.running || view.success !== false) {
    return undefined;
  }
  const stages = view.progress?.stages || [];
  for (let index = stages.length - 1; index >= 0; index -= 1) {
    if (stages[index].id !== 'rollback') {
      return { id: stages[index].id, index };
    }
  }
  return undefined;
}

interface StageRow {
  id: Stage;
  state: 'done' | 'current' | 'failed' | 'pending';
  startedAt: number;
  finishedAt: number | null;
}

export function stageRows(
  view: Prokop.ComponentProgressView,
  installed = true,
): StageRow[] {
  const observed = view.progress?.stages || [];
  const failedIndex = failedStageOf(view)?.index ?? -1;
  const rows: StageRow[] = observed.map((stage, index) => {
    const last = index === observed.length - 1;
    let state: StageRow['state'] = 'done';

    if (last && view.running) {
      state = 'current';
    } else if (index === failedIndex) {
      state = 'failed';
    }

    return {
      id: stage.id,
      state,
      startedAt: stage.started_at,
      finishedAt: stage.finished_at,
    };
  });

  // Without a report from the router there is no stage to place the plan
  // against; once it restores after a failure, nothing of the plan is ahead.
  if (
    !view.running ||
    !view.progress ||
    observed.some((stage) => stage.id === 'rollback')
  ) {
    return rows;
  }

  const plan = plannedStages(view.component, view.action, installed);
  const reached = observed.reduce(
    (max, stage) => Math.max(max, plan.indexOf(stage.id)),
    -1,
  );

  plan.forEach((stage, index) => {
    if (index > reached && !observed.some((item) => item.id === stage)) {
      rows.push({
        id: stage,
        state: 'pending',
        startedAt: 0,
        finishedAt: null,
      });
    }
  });

  return rows;
}

const ELAPSED_ATTRIBUTE = 'data-fkp-progress-since';
const REVEAL_ATTRIBUTE = 'data-fkp-progress-reveal-at';

function withAttributes<T extends HTMLElement>(
  node: T,
  attributes: Record<string, string>,
) {
  Object.entries(attributes).forEach(([name, value]) =>
    node.setAttribute(name, value),
  );
  return node;
}

function elapsedNode(since: number) {
  const node = E(
    'span',
    { class: 'fkp_component-progress__time' },
    asText(formatDuration(routerNowSeconds() - since)),
  );
  node.setAttribute(ELAPSED_ATTRIBUTE, String(since));
  return node;
}

let tickTimer: ReturnType<typeof setInterval> | null = null;

// The running times go on between two answers from the router.
function tickElapsed() {
  const nodes = document.querySelectorAll(`[${ELAPSED_ATTRIBUTE}]`);

  document
    .querySelectorAll<HTMLElement>(`[${REVEAL_ATTRIBUTE}]`)
    .forEach((node) => {
      node.hidden =
        routerNowSeconds() < Number(node.getAttribute(REVEAL_ATTRIBUTE));
    });

  if (nodes.length === 0) {
    if (tickTimer !== null) {
      clearInterval(tickTimer);
      tickTimer = null;
    }
    return;
  }

  const now = routerNowSeconds();
  nodes.forEach((node) => {
    const since = Number(node.getAttribute(ELAPSED_ATTRIBUTE));
    if (Number.isFinite(since) && since > 0) {
      node.textContent = formatDuration(now - since);
    }
  });
}

function ensureTicker() {
  if (tickTimer === null && typeof window !== 'undefined') {
    tickTimer = setInterval(() => {
      if (isPageHidden()) {
        return;
      }
      tickElapsed();
    }, 1000);
  }
}

function renderStageRow(row: StageRow) {
  const marks: Record<StageRow['state'], string> = {
    done: '✓',
    current: '●',
    failed: '✕',
    pending: '○',
  };
  const children: Node[] = [
    withAttributes(
      E(
        'span',
        { class: 'fkp_component-progress__mark' },
        asText(marks[row.state]),
      ),
      { 'aria-hidden': 'true' },
    ),
    E(
      'span',
      { class: 'fkp_component-progress__label' },
      asText(stageLabel(row.id)),
    ),
  ];

  if (row.state === 'current' && row.startedAt) {
    children.push(elapsedNode(row.startedAt));
  } else if (
    (row.state === 'done' || row.state === 'failed') &&
    row.finishedAt !== null &&
    row.finishedAt >= row.startedAt
  ) {
    children.push(
      E(
        'span',
        { class: 'fkp_component-progress__time' },
        asText(formatDuration(row.finishedAt - row.startedAt)),
      ),
    );
  }

  return E(
    'li',
    {
      class: `fkp_component-progress__stage fkp_component-progress__stage--${row.state}`,
    },
    children,
  );
}

export function renderComponentProgress(
  view: Prokop.ComponentProgressView,
  {
    installed = true,
    onDismiss,
  }: { installed?: boolean; onDismiss?: () => void } = {},
) {
  const children: Node[] = [];
  const startedAt = viewStartedAt(view);
  const failedStage = failedStageOf(view)?.id;

  // 1. What it is doing now, or how it ended, and for how long.
  const summary: Node[] = [];
  if (view.running) {
    summary.push(
      E(
        'b',
        { class: 'fkp_component-progress__title' },
        asText(stageLabel(view.progress?.stage || '')),
      ),
    );
    if (startedAt) {
      summary.push(
        E('span', { class: 'fkp_component-progress__caption' }, [
          document.createTextNode(`${_('Elapsed:')} `),
          elapsedNode(startedAt),
        ]),
      );
    }
  } else {
    const duration = viewDuration(view);
    let title: string;

    if (view.success) {
      title =
        duration !== null
          ? _('Done in %s').replace('%s', formatDuration(duration))
          : _('Done');
    } else if (failedStage) {
      title =
        duration !== null
          ? _('Failed at “%s” after %s')
              .replace('%s', stageLabel(failedStage))
              .replace('%s', formatDuration(duration))
          : _('Failed at “%s”').replace('%s', stageLabel(failedStage));
    } else {
      title = _('Failed');
    }

    summary.push(
      E(
        'b',
        {
          class: `fkp_component-progress__title fkp_component-progress__title--${view.success ? 'done' : 'failed'}`,
        },
        asText(title),
      ),
    );
  }

  children.push(
    E('div', { class: 'fkp_component-progress__summary' }, summary),
  );

  // 2. The current download.
  const download = view.running ? view.progress?.download : null;
  if (download && view.progress?.stage === 'download') {
    children.push(
      E(
        'div',
        { class: 'fkp_component-progress__download' },
        asText(downloadText(download)),
      ),
    );
    if (download.total > 0) {
      const percent = Math.min(
        100,
        Math.floor((download.bytes / download.total) * 100),
      );
      const bar = withAttributes(
        E('div', { class: 'fkp_component-progress__bar' }),
        {
          role: 'progressbar',
          'aria-valuemin': '0',
          'aria-valuemax': '100',
          'aria-valuenow': String(percent),
        },
      );
      bar.appendChild(
        E('div', {
          class: 'fkp_component-progress__bar-fill',
          style: `width: ${percent}%`,
        }),
      );
      children.push(bar);
    }
  }

  // 3. The result in words.
  if (!view.running && view.message) {
    children.push(
      E(
        'div',
        {
          class: `fkp_component-progress__message fkp_component-progress__message--${view.success ? 'done' : 'failed'}`,
        },
        asText(view.message),
      ),
    );
  }

  // 4. The stages, done and ahead.
  const rows = stageRows(view, installed);
  if (rows.length > 0) {
    children.push(
      E(
        'ul',
        { class: 'fkp_component-progress__stages' },
        rows.map(renderStageRow),
      ),
    );
  } else if (view.running && startedAt) {
    // A release before this one reports no stages; a worker that just
    // started has not yet. Said only once it has had time to.
    const caption = E(
      'div',
      { class: 'fkp_component-progress__caption' },
      asText(_('The router does not report the stages of this action')),
    );
    caption.setAttribute(REVEAL_ATTRIBUTE, String(startedAt + 5));
    caption.hidden = routerNowSeconds() < startedAt + 5;
    children.push(caption);
  }

  if (
    view.running &&
    view.component === 'prokop' &&
    view.action === 'install'
  ) {
    children.push(
      E(
        'div',
        { class: 'fkp_component-progress__caption' },
        asText(
          _(
            'The connection to the router may drop for a moment while Prokop is installed and restarted; the progress is kept and the page picks it up again.',
          ),
        ),
      ),
    );
  }

  if (!view.running && onDismiss) {
    children.push(
      E(
        'button',
        {
          type: 'button',
          class: 'cbi-button fkp_component-progress__dismiss',
          click: () => onDismiss(),
        },
        asText(_('Hide')),
      ),
    );
  }

  if (view.running) {
    ensureTicker();
  }

  return withAttributes(
    E(
      'div',
      {
        class: `fkp_component-progress fkp_component-progress--${view.running ? 'running' : view.success ? 'done' : 'failed'}`,
      },
      children,
    ),
    { 'aria-live': 'polite' },
  );
}
