import { renderButton } from '../../../../partials';
import { renderSearchIcon24 } from '../../../../icons';

interface IRenderDiagnosticRunActionProps {
  loading: boolean;
  disabled?: boolean;
  click: () => void;
}

export function renderRunAction({
  loading,
  disabled,
  click,
}: IRenderDiagnosticRunActionProps) {
  return E('div', { class: 'fkp_diagnostic-page__run_check_wrapper' }, [
    renderButton({
      text: _('Run full diagnostics'),
      onClick: click,
      icon: renderSearchIcon24,
      loading,
      disabled,
      classNames: ['cbi-button-apply'],
    }),
  ]);
}

const LAST_RUN_KEY = 'prokop.diagnostic.lastRun';

export function saveLastRun(
  storage: Pick<Storage, 'setItem'>,
  now = Date.now(),
) {
  try {
    storage.setItem(LAST_RUN_KEY, String(now));
  } catch (_error) {
    /* private mode or disabled storage */
  }
}

export function readLastRun(storage: Pick<Storage, 'getItem'>) {
  let value = 0;
  try {
    value = Number(storage.getItem(LAST_RUN_KEY) || 0);
  } catch (_error) {
    value = 0;
  }
  return value > 0 ? value : null;
}

export function lastRunText(storage: Pick<Storage, 'getItem'>) {
  const value = readLastRun(storage) || 0;
  return value > 0
    ? `${_('Last check')}: ${new Date(value).toLocaleString()}`
    : _('No check has been run yet');
}
