import { showToast } from '../../../helpers/showToast';
import { isReadonlyMode } from '../../services/accessMode.service';
import { serviceActionErrorText } from '../diagnostic/serviceTransition';
import { runProkopServiceAction } from './serviceControl';

let starting = false;

// Pages that say "the service is stopped" offer to start it right there.
// Read-only sessions get no button.
export function renderStartServiceAction(): HTMLElement[] {
  if (isReadonlyMode()) {
    return [];
  }

  const button = E(
    'button',
    {
      type: 'button',
      class: 'btn cbi-button cbi-button-action fkp-start-service',
      disabled: starting ? true : undefined,
      click: async () => {
        if (starting) {
          return;
        }

        starting = true;
        button.disabled = true;
        button.textContent = _('Starting…');
        try {
          await runProkopServiceAction('start');
        } catch (error) {
          showToast(serviceActionErrorText(error), 'error', 6000);
        } finally {
          starting = false;
          button.disabled = false;
          button.textContent = _('Start Prokop');
        }
      },
    },
    starting ? _('Starting…') : _('Start Prokop'),
  );

  return [button];
}
