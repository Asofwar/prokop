import { Prokop } from '../../types';
import { PROKOP_UCI_PACKAGE } from '../../../constants';
import { ProkopShellMethods } from '../shell';

type UciLocalState = Partial<
  Record<
    'changes' | 'creates' | 'deletes' | 'reorder',
    Record<string, unknown> | undefined
  >
>;

// Edits made on this page and not yet saved live only in LuCI's uci state;
// dropping the package would lose them.
function hasLocalChanges(conf: string) {
  const state = (uci as unknown as { state?: UciLocalState }).state;

  return (['changes', 'creates', 'deletes', 'reorder'] as const).some((key) => {
    const value = state?.[key]?.[conf];
    return (
      value !== undefined &&
      value !== null &&
      (typeof value !== 'object' || Object.keys(value).length > 0)
    );
  });
}

// LuCI's uci.load() returns the copy loaded with the page, so a page that
// refreshes would keep showing the configuration as of its load. The package
// is read again on each call unless this page holds unsaved edits (UC-127).
export async function getConfigSections(): Promise<Prokop.ConfigSection[]> {
  try {
    if (!hasLocalChanges(PROKOP_UCI_PACKAGE)) {
      uci.unload?.(PROKOP_UCI_PACKAGE);
    }
    await uci.load(PROKOP_UCI_PACKAGE);
    return await uci.sections(PROKOP_UCI_PACKAGE);
  } catch (_error) {
    const response = await ProkopShellMethods.getReadonlyConfigSections();
    return response.success ? response.data : [];
  }
}
