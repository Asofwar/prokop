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
    case 'torrserver':
      return 'TorrServer';
    case 'torrserver_direct':
      return _('TorrServer Direct');
    default:
      return component;
  }
}

// A success that left something undone: TorrServer installed, but its
// recommended settings did not take (TS-11). The toast warns instead.
export function componentActionSuccessIsPartial(
  result: Pick<Prokop.ComponentActionResult, 'component' | 'settings_applied'>,
): boolean {
  return result.component === 'torrserver' && result.settings_applied === 0;
}

// The success toast is built from the component and the action: the
// backend message is English prose meant for logs (UC-130).
export function componentActionSuccessText(
  result: Pick<
    Prokop.ComponentActionResult,
    'component' | 'action' | 'status' | 'settings_applied'
  >,
): string {
  const { component, action } = result;

  if (componentActionSuccessIsPartial(result)) {
    return _(
      'TorrServer has been installed, but the recommended settings were not applied. Apply them with the button on the card',
    );
  }

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
  if (action === 'start') {
    return _('%s has been started').replace('%s', name);
  }
  if (action === 'apply_settings') {
    return _('Recommended %s settings have been applied').replace('%s', name);
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

// TorrServer's failures (components/action.uc install_torrserver,
// start_torrserver, apply_torrserver_settings, remove_torrserver and
// set_torrserver_direct) in the UI's language: the backend writes English
// for the log. Any other message is returned unchanged.
const TORRSERVER_FAILURES: Array<
  [RegExp, (match: RegExpMatchArray) => string]
> = [
  [/^TorrServer is not installed$/, () => _('TorrServer is not installed')],
  [
    /^TorrServer service is not available in this Prokop build$/,
    () => _('This Prokop build cannot install TorrServer'),
  ],
  [
    /^Failed to read TorrServer paths$/,
    () => _('Failed to read where TorrServer is installed'),
  ],
  [
    /^Failed to create (\/\S*)$/,
    (m) => _('Failed to create the folder %s').replace('%s', m[1]),
  ],
  [
    /^Failed to stage TorrServer on the router's storage/,
    () =>
      _(
        "Failed to save TorrServer on the router's storage; nothing was installed",
      ),
  ],
  [
    /^Failed to keep the installed TorrServer aside for the update/,
    () =>
      _(
        'Failed to set the installed TorrServer aside for the update; it runs on unchanged',
      ),
  ],
  [
    /^Failed to install TorrServer; the previous version was restored$/,
    () => _('Failed to install TorrServer; the previous version was restored'),
  ],
  [
    /^Failed to install TorrServer; the previous version could not be restored$/,
    () =>
      _(
        'Failed to install TorrServer, and the previous version could not be restored',
      ),
  ],
  [/^Failed to install TorrServer$/, () => _('Failed to install TorrServer')],
  [/^Failed to remove TorrServer$/, () => _('Failed to remove TorrServer')],
  [
    /^TorrServer (\S+) did not start$/,
    (m) => _('TorrServer %s did not start').replace('%s', m[1]),
  ],
  [
    /^TorrServer Direct service is not available$/,
    () => _('This Prokop build has no direct routing for TorrServer'),
  ],
  [
    /^This firmware does not provide kmod-nft-socket/,
    () =>
      _(
        'This firmware has no kmod-nft-socket package, which direct routing for TorrServer needs',
      ),
  ],
  [/^TorrServer is not running$/, () => _('TorrServer is not running')],
  [
    /^TorrServer does not have a dedicated cgroup$/,
    () =>
      _(
        'TorrServer does not run in its own service group. Install TorrServer from Prokop to use direct routing for it.',
      ),
  ],
  [
    /^Failed to save TorrServer Direct settings$/,
    () => _('Failed to save the direct routing setting for TorrServer'),
  ],
  [
    /^Failed to apply TorrServer Direct settings$/,
    () => _('Failed to apply direct routing for TorrServer'),
  ],
  [
    /^TorrServer publishes no build for this router's CPU$/,
    () => _("TorrServer publishes no build for this router's CPU"),
  ],
  [
    /^Failed to read the latest TorrServer release$/,
    () =>
      _(
        'Failed to read the latest TorrServer release. Check the internet connection and try again',
      ),
  ],
  [
    /^The latest TorrServer release has no verified build for (\S+)$/,
    (m) =>
      _(
        'The latest TorrServer release has no build with a published checksum for %s',
      ).replace('%s', m[1]),
  ],
  [
    /^Another TorrServer is installed or running on this router/,
    () =>
      _(
        'Another TorrServer is installed or running on this router; Prokop does not replace it',
      ),
  ],
  [
    /^The installed TorrServer binary does not match the checksum Prokop recorded/,
    () =>
      _(
        'The TorrServer program was changed outside Prokop; Prokop left it as it is',
      ),
  ],
  [
    /^This TorrServer was not installed by Prokop/,
    () =>
      _('This TorrServer was not installed by Prokop; Prokop left it as it is'),
  ],
  [
    /^Not enough free space .*TorrServer: ([0-9]+) KiB available where ([0-9]+) KiB is needed$/,
    (m) =>
      _('Not enough free space for TorrServer: %s KiB free, %s KiB needed')
        .replace('%s', m[1])
        .replace('%s', m[2]),
  ],
  [
    /^Not enough free memory to download TorrServer/,
    () => _('Not enough free memory to download TorrServer'),
  ],
  [/^Failed to download TorrServer$/, () => _('Failed to download TorrServer')],
  [
    /^Downloaded TorrServer does not match/,
    () =>
      _(
        'The downloaded TorrServer does not match its published checksum; nothing was installed',
      ),
  ],
  [
    /^The downloaded TorrServer does not run on this router/,
    () =>
      _(
        'The downloaded TorrServer does not run on this router; nothing was installed',
      ),
  ],
  [
    /^TorrServer (\S+) did not start; the previous version (\S+) runs again$/,
    (m) =>
      _('TorrServer %s did not start; the previous version %s runs again')
        .replace('%s', m[1])
        .replace('%s', m[2]),
  ],
  [
    /^TorrServer (\S+) did not start; the previous version (\S+) could not be started again$/,
    (m) =>
      _(
        'TorrServer %s did not start, and the previous version %s did not start again either',
      )
        .replace('%s', m[1])
        .replace('%s', m[2]),
  ],
  [
    /^TorrServer (\S+) did not start and was removed$/,
    (m) => _('TorrServer %s did not start and was removed').replace('%s', m[1]),
  ],
  [/^Failed to stop TorrServer$/, () => _('Failed to stop TorrServer')],
  [
    /^TorrServer is stopped; start it to apply the settings$/,
    () => _('TorrServer is stopped; start it to apply the settings'),
  ],
  [
    /^TorrServer did not take the recommended settings$/,
    () => _('TorrServer did not take the recommended settings'),
  ],
];

export function componentActionFailureText(message: string): string {
  for (const [pattern, text] of TORRSERVER_FAILURES) {
    const match = message.match(pattern);
    if (match) {
      return text(match);
    }
  }
  return message;
}
