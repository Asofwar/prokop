import type { StoreType } from '../services/store.service';
import type { Prokop } from '../types';

export type UpdatesActionKey = keyof StoreType['updatesActions'];

const componentActionKeyMap: Record<string, UpdatesActionKey> = {
  'prokop:check_update': 'prokopCheck',
  'prokop:install': 'prokopInstall',
  'sing_box:check_update': 'singBoxCheck',
  'sing_box:install': 'singBoxInstall',
  'sing_box:install_extended': 'singBoxInstallExtended',
  'sing_box:install_extended_compressed': 'singBoxInstallExtendedCompressed',
  'sing_box:install_tiny': 'singBoxInstallTiny',
  'sing_box:install_stable': 'singBoxInstallStable',
  'zapret:check_update': 'zapretCheck',
  'zapret:install': 'zapretInstall',
  'zapret:remove': 'zapretRemove',
  'zapret2:check_update': 'zapret2Check',
  'zapret2:install': 'zapret2Install',
  'zapret2:remove': 'zapret2Remove',
  'byedpi:check_update': 'byedpiCheck',
  'byedpi:install': 'byedpiInstall',
  'byedpi:remove': 'byedpiRemove',
  'zapret_manager:install': 'zapretManagerInstall',
  'zapret_manager:remove': 'zapretManagerRemove',
  'packet_steering:enable': 'packetSteeringEnable',
  'packet_steering:restore': 'packetSteeringRestore',
  'direct_proxy:enable': 'directProxyEnable',
  'direct_proxy:disable': 'directProxyDisable',
  'torrserver_direct:enable': 'torrserverDirectEnable',
  'torrserver_direct:disable': 'torrserverDirectDisable',
};

export function getComponentActionKey(
  component: Prokop.ComponentName,
  action: Prokop.ComponentAction,
): UpdatesActionKey | undefined {
  return componentActionKeyMap[`${component}:${action}`];
}
