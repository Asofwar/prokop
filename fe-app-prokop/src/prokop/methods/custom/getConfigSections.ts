import { Prokop } from '../../types';
import { PROKOP_UCI_PACKAGE } from '../../../constants';
import { ProkopShellMethods } from '../shell';

export async function getConfigSections(): Promise<Prokop.ConfigSection[]> {
  try {
    await uci.load(PROKOP_UCI_PACKAGE);
    return await uci.sections(PROKOP_UCI_PACKAGE);
  } catch (_error) {
    const response = await ProkopShellMethods.getReadonlyConfigSections();
    return response.success ? response.data : [];
  }
}
