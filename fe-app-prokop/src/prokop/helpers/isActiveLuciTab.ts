import { getProkopPage } from '../services/prokopPage';

export function isActiveLuciTab(tabId: string) {
  if (getProkopPage() === tabId) {
    return true;
  }

  if (typeof document === 'undefined') {
    return false;
  }

  return Boolean(
    document.querySelector(
      `.cbi-tab[data-tab="${tabId}"]:not(.cbi-tab-disabled)`,
    ),
  );
}
