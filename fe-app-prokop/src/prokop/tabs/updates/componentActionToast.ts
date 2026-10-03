import { Prokop } from '../../types';

function componentName(component: Prokop.ComponentName): string {
  switch (component) {
    case 'prokop':
      return 'Prokop';
    case 'sing_box':
      return 'sing-box';
    case 'zapret':
      return 'Zapret';
    case 'zapret2':
      return 'Zapret2';
    case 'byedpi':
      return 'ByeDPI';
    case 'zapret_manager':
      return 'Zapret-Manager';
    case 'packet_steering':
      return 'Packet Steering';
    case 'direct_proxy':
      return _('Direct Proxy');
    case 'torrserver_direct':
      return _('TorrServer Direct');
    default:
      return component;
  }
}

// The success toast is built from the component and the action: the
// backend message is English prose meant for logs (UC-130).
export function componentActionSuccessText(
  result: Pick<Prokop.ComponentActionResult, 'component' | 'action' | 'status'>,
): string {
  const { component, action } = result;

  if (component === 'prokop' && result.status === 'recovered') {
    return _(
      'The interrupted Prokop update was rolled back; no new update was attempted',
    );
  }

  if (component === 'packet_steering') {
    if (action === 'enable') {
      return _('Packet Steering mode 2 has been enabled');
    }
    if (action === 'restore') {
      return _('Packet Steering normal mode has been restored');
    }
  }

  const name = componentName(component);

  if (action === 'install' || action.startsWith('install_')) {
    return _('%s has been installed').replace('%s', name);
  }
  if (action === 'remove') {
    return _('%s has been removed').replace('%s', name);
  }
  if (action === 'enable') {
    return _('%s has been enabled').replace('%s', name);
  }
  if (action === 'disable') {
    return _('%s has been disabled').replace('%s', name);
  }

  return _('Action completed');
}
