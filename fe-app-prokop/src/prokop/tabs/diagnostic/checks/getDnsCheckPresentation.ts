import type { Prokop } from '../../../types';
import { getMeta } from '../helpers/getMeta';

type DnsCheckState = 'error' | 'success' | 'warning';

export function getDnsCheckPresentation(data: Prokop.DnsCheckResult) {
  const dhcpManagedManually = Boolean(data.dont_touch_dhcp);
  const dhcpCheckOk = dhcpManagedManually || Boolean(data.dhcp_config_status);
  // Keep Bootstrap DNS mandatory for an older backend that does not send this field.
  const bootstrapCheckRequired = data.bootstrap_dns_required !== 0;
  const bootstrapCheckOk =
    !bootstrapCheckRequired || Boolean(data.bootstrap_dns_status);

  const allGood =
    Boolean(data.dns_on_router) &&
    dhcpCheckOk &&
    bootstrapCheckOk &&
    Boolean(data.dns_status);

  const atLeastOneGood =
    Boolean(data.dns_on_router) ||
    dhcpCheckOk ||
    bootstrapCheckOk ||
    Boolean(data.dns_status);

  const meta = getMeta({ atLeastOneGood, allGood });
  // C8: something on the way answers plain DNS in place of the servers.
  const intercepted = data.dns_interception === 1;
  const state: DnsCheckState =
    (dhcpManagedManually || intercepted) && meta.state === 'success'
      ? 'warning'
      : meta.state;
  const description =
    intercepted && meta.state === 'success'
      ? _('Checks passed, but plain DNS is intercepted on the way')
      : dhcpManagedManually && meta.state === 'success'
        ? _('Checks passed with manual DHCP')
        : meta.description;

  const dhcpItemState: DnsCheckState = dhcpManagedManually
    ? 'warning'
    : data.dhcp_config_status
      ? 'success'
      : 'error';
  const dhcpItemKey = dhcpManagedManually
    ? _('DHCP is managed manually')
    : _('DHCP has DNS server');

  return {
    state,
    description,
    dhcpItemState,
    dhcpItemKey,
    intercepted,
  };
}
