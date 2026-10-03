import { getClashApiSecretFromSettings } from '../../../helpers/getClashApiUrl';
import { getConfigSections } from './getConfigSections';

// Read-only sessions cannot read the option (uci is denied and the read-only
// section list never carries it), so they get '' and use rpcd polling.
export async function getClashApiSecret() {
  const sections = await getConfigSections();

  const settings = sections.find((section) => section['.type'] === 'settings');

  return getClashApiSecretFromSettings(settings);
}
