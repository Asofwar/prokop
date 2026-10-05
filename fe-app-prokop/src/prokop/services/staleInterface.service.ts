import { asText } from '../../helpers/asText';
import { PROKOP_LUCI_APP_VERSION } from '../../constants';
import { logger } from './logger.service';
import { ensureSystemInfo } from './systemInfo.service';

const RELEASE_VERSION = /^\d+\.\d+\.\d+(?:[-~][0-9A-Za-z.]+)?$/;

// C5: LuCI loads view modules with the version of luci-base, not of
// luci-app-prokop, and uhttpd sends them without Cache-Control, so after an
// update the browser could keep running the previous main.js against the new
// backend. The version compiled into the loaded script is compared with the
// one in main.js on the router (diagnostics get-system-info). Only two
// release versions that differ count: a development build or an unknown
// version says nothing.
export function isStaleInterface(loaded: string, installed: string) {
  const loadedVersion = `${loaded ?? ''}`.trim();
  const installedVersion = `${installed ?? ''}`.trim();

  return (
    RELEASE_VERSION.test(loadedVersion) &&
    RELEASE_VERSION.test(installedVersion) &&
    loadedVersion !== installedVersion
  );
}

export function staleInterfaceMessage(loaded: string, installed: string) {
  return _(
    'This page was loaded from the browser cache: it is version %s, while version %s is installed on the router. Reload the page bypassing the cache (Ctrl+F5, or Cmd+Shift+R on a Mac).',
  )
    .replace('%s', loaded)
    .replace('%s', installed);
}

export async function checkStaleInterface(loaded = PROKOP_LUCI_APP_VERSION) {
  try {
    const systemInfo = await ensureSystemInfo({ silent: true });
    if (!isStaleInterface(loaded, systemInfo.luci_app_version)) {
      return false;
    }

    ui.addNotification(
      _('The Prokop interface is out of date'),
      E(
        'div',
        {},
        asText(staleInterfaceMessage(loaded, systemInfo.luci_app_version)),
      ),
      'warning',
      'fkp-stale-interface-notification',
    );
    return true;
  } catch (error) {
    logger.error('[STALE_INTERFACE]', 'version check failed', error);
    return false;
  }
}
