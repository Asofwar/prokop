import { ProkopShellMethods } from '../../methods';
import type { StatusTone } from './statusLabels';

type Provider = 'zapret' | 'zapret2' | 'byedpi';

export function validationView(response: {
  success: boolean;
  data?: unknown;
}): { text: string; tone: StatusTone } {
  const data = response.data as
    | { valid?: unknown; message?: unknown }
    | undefined;
  if (!response.success || typeof data?.valid !== 'boolean')
    return { text: _('Syntax check is unavailable'), tone: 'error' };
  if (data.valid)
    return { text: `✓ ${_('Syntax is correct')}`, tone: 'success' };
  const message = typeof data.message === 'string' ? data.message.trim() : '';
  return {
    text: `✕ ${message || _('The strategy contains an error')}`,
    tone: 'error',
  };
}

export function initDpiPlayground() {
  const button = document.getElementById(
    'dpi-validate',
  ) as HTMLButtonElement | null;
  const input = document.getElementById(
    'dpi-strategy',
  ) as HTMLTextAreaElement | null;
  const provider = document.getElementById(
    'dpi-provider',
  ) as HTMLSelectElement | null;
  const result = document.getElementById('dpi-playground-result');
  if (!button || !input || !provider || !result || button.onclick) return;
  const clear = () => result.replaceChildren();
  input.oninput = clear;
  provider.onchange = clear;
  button.onclick = async () => {
    const strategy = input.value.trim();
    if (!strategy) {
      result.className = 'fkp-diag-text--error';
      result.textContent = _('Enter a strategy');
      return;
    }
    button.disabled = true;
    result.className = 'fkp-diag-text--loading';
    result.textContent = _('Checking…');
    try {
      const response = await ProkopShellMethods.validateDpiStrategy(
        provider.value as Provider,
        strategy,
      );
      if (input.value.trim() !== strategy) return;
      const view = validationView(response);
      result.className = `fkp-diag-text--${view.tone}`;
      result.textContent = view.text;
    } catch (_error) {
      if (input.value.trim() !== strategy) return;
      const view = validationView({ success: false });
      result.className = `fkp-diag-text--${view.tone}`;
      result.textContent = view.text;
    } finally {
      button.disabled = false;
    }
  };
}
