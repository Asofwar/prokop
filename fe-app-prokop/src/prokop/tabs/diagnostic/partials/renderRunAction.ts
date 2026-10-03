import { renderButton } from '../../../../partials';
import { renderSearchIcon24 } from '../../../../icons';
import {
  DIAGNOSTIC_LAST_RUN_KEY,
  readStorageItem,
  writeStorageItem,
  type ReadableStorage,
  type WritableStorage,
} from '../../../helpers/legacyStorage';
import { formatDateTime } from '../../../ui/time';

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

export function saveLastRun(storage: WritableStorage, now = Date.now()) {
  try {
    writeStorageItem(storage, DIAGNOSTIC_LAST_RUN_KEY, String(now));
  } catch (_error) {
    /* private mode or disabled storage */
  }
}

export function readLastRun(storage: ReadableStorage) {
  let value = 0;
  try {
    value = Number(readStorageItem(storage, DIAGNOSTIC_LAST_RUN_KEY) || 0);
  } catch (_error) {
    value = 0;
  }
  return value > 0 ? value : null;
}

export function lastRunText(storage: ReadableStorage) {
  const value = readLastRun(storage) || 0;
  return value > 0
    ? `${_('Last check')}: ${formatDateTime(value / 1000)}`
    : _('No check has been run yet');
}
