import { executeShellCommand } from '../../../helpers/executeShellCommand';
import { renderButton } from '../../../partials';
import { releaseLacksKillSwitch } from './killSwitchRelease';

const RELEASE_VERSION = /^\d+\.\d+\.\d+$/;
const RELEASES_TIMEOUT_MS = 75_000;

interface CatalogRelease {
  version: string;
  channel: string;
}

async function loadReleases(): Promise<CatalogRelease[]> {
  const response = await executeShellCommand({
    command: '/usr/bin/prokop',
    args: ['prokop_releases'],
    timeout: RELEASES_TIMEOUT_MS,
  });

  const result = JSON.parse(response.stdout || '{}');
  if (
    (response.code ?? 0) !== 0 ||
    !result.success ||
    !Array.isArray(result.releases)
  ) {
    throw new Error(_('Could not load available versions'));
  }

  return (result.releases as CatalogRelease[]).filter((release) =>
    RELEASE_VERSION.test(`${release?.version}`),
  );
}

function confirmVersionChange(
  currentVersion: string,
  version: string,
  install: (version: string) => void,
) {
  const cancel = renderButton({
    text: _('Cancel'),
    onClick: () => ui.hideModal(),
  });
  ui.showModal(
    _('Confirm version change'),
    E('div', {}, [
      E('p', {}, `${currentVersion} → ${version}`),
      E(
        'p',
        {},
        _(
          'A configuration backup will be saved in /etc/prokop-backups. Older versions may not support all current settings.',
        ),
      ),
      ...(releaseLacksKillSwitch(version)
        ? [
            E(
              'p',
              {},
              _(
                'Prokop 1.0.31 and older have no VPN kill-switch. If it is enabled, the installation removes its protection, and protected traffic is no longer blocked while Prokop is stopped.',
              ),
            ),
          ]
        : []),
      E('div', { class: 'right' }, [
        cancel,
        renderButton({
          text: _('Install'),
          classNames: ['cbi-button-save'],
          onClick: () => {
            ui.hideModal();
            install(version);
          },
        }),
      ]),
    ]),
  );
  // Cancel is the default focus, as in confirmAction (UC-133).
  cancel.focus();
}

// Buttons sit in a '.right' container with Cancel or Close first: LuCI's
// Escape handler clicks the first '.right > button' of the modal (UC-134).
export async function showReleaseSelector(
  currentVersion: string,
  install: (version: string) => void,
) {
  const status = E('p', { role: 'status' }, _('Loading available versions…'));
  const content = E('div', {}, [
    status,
    E('div', { class: 'right' }, [
      renderButton({ text: _('Cancel'), onClick: () => ui.hideModal() }),
    ]),
  ]);
  ui.showModal(_('Choose Prokop version'), content);

  try {
    const releases = await loadReleases();
    const select = E('select', {
      class: 'cbi-input-select',
      'aria-label': _('Choose Prokop version'),
    }) as HTMLSelectElement;

    for (const release of releases) {
      const installed = release.version === currentVersion;
      select.appendChild(
        E(
          'option',
          { value: release.version },
          `${release.version}${installed ? ` — ${_('Installed')}` : ''}`,
        ),
      );
    }

    if (!select.options.length) {
      throw new Error(_('No compatible releases available'));
    }

    const confirm = renderButton({
      text: _('Install selected version'),
      classNames: ['cbi-button-save'],
      onClick: () =>
        confirmVersionChange(currentVersion, select.value, install),
    });

    // Reinstalling the running version is never what this dialog is for.
    const update = () => {
      (confirm as HTMLButtonElement).disabled = select.value === currentVersion;
    };
    select.addEventListener('change', update);
    update();

    content.replaceChildren(
      select,
      E('div', { class: 'right' }, [
        renderButton({ text: _('Cancel'), onClick: () => ui.hideModal() }),
        confirm,
      ]),
    );
  } catch (error) {
    status.textContent =
      error instanceof Error
        ? error.message
        : _('Could not load available versions');
    content.replaceChildren(
      status,
      E('div', { class: 'right' }, [
        renderButton({ text: _('Close'), onClick: () => ui.hideModal() }),
      ]),
    );
  }
}
