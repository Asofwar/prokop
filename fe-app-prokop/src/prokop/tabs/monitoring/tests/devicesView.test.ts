import { afterEach, describe, expect, it, vi } from 'vitest';

vi.mock('../../../../icons', () => ({ renderSearchIcon24: () => '' }));
vi.mock('../../../ui/status', () => ({ renderProvenance: () => '' }));
vi.mock('../../../ui/time', () => ({ formatDateTime: () => 'date' }));

import { renderDevicesPanel, type DevicesViewModel } from '../devicesView';

afterEach(() => vi.unstubAllGlobals());

interface Node {
  tag: string;
  children: unknown;
}

function text(node: unknown): string {
  if (node == null) return '';
  if (typeof node === 'string') return node;
  if (Array.isArray(node)) return node.map(text).join(' ');
  if (typeof node === 'object' && 'children' in (node as Node))
    return text((node as Node).children);
  return '';
}

function model(values: Partial<DevicesViewModel>): DevicesViewModel {
  return {
    status: 'ok',
    since: 1000,
    offload: 'none',
    full: false,
    totalDevices: null,
    shownDevices: 0,
    rows: [],
    showConnections: () => {},
    startServiceActions: () => [],
    ...values,
  };
}

describe('devices panel notes', () => {
  it('says what is counted, and warns of a full list and a cut answer', () => {
    vi.stubGlobal('_', (value: string) => value);
    vi.stubGlobal(
      'E',
      (tag: string, _attributes: unknown, children: unknown) => ({
        tag,
        children,
      }),
    );
    const plain = text(renderDevicesPanel(model({})));
    expect(plain).toContain('traffic between devices of the LAN is not seen');
    expect(plain).toContain(
      'An address idle for 7 days starts again from zero',
    );
    expect(plain).not.toContain('list of addresses is full');

    const warned = text(
      renderDevicesPanel(
        model({ full: true, totalDevices: 1028, shownDevices: 200 }),
      ),
    );
    expect(warned).toContain('list of addresses is full');
    expect(warned).toContain(
      'Shown: the 200 addresses with the most traffic of 1028.',
    );
  });
});
