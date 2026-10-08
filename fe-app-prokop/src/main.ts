'use strict';
'require baseclass';
'require fs';
'require uci';
'require ui';

if (typeof structuredClone !== 'function')
  globalThis.structuredClone = (obj) => JSON.parse(JSON.stringify(obj));

export { attachDnsProfiles } from './prokop/dnsProfiles';
export { validateIP } from './validators/validateIp';
export { validateDomain } from './validators/validateDomain';
export { validateDNS, validateBootstrapDNS } from './validators/validateDns';
export { validateUrl } from './validators/validateUrl';
export { validatePath } from './validators/validatePath';
export { validateSubnet } from './validators/validateSubnet';
export { validateOutboundJson } from './validators/validateOutboundJson';
export { validateProxyUrl } from './validators/validateProxyUrl';
export { parseValueList } from './helpers/parseValueList';
export { getProxyUrlName } from './helpers/getProxyUrlName';
export { injectGlobalStyles } from './helpers/injectGlobalStyles';
export { getClashUIUrl } from './helpers/getClashApiUrl';
export { ProkopShellMethods } from './prokop/methods/shell';
export { coreService } from './prokop/services/core.service';
export { setReadonlyMode } from './prokop/services/accessMode.service';
export { setProkopPage } from './prokop/services/tab.service';
export { store } from './prokop/services/store.service';
export { applyUiStateToStore } from './prokop/services/uiState.service';
export { DashboardTab } from './prokop/tabs/dashboard';
export { DiagnosticTab } from './prokop/tabs/diagnostic';
export { MonitoringTab } from './prokop/tabs/monitoring';
export { UpdatesTab } from './prokop/tabs/updates';
export { HistoryTab } from './prokop/tabs/history';
export { AutotuneTab } from './prokop/tabs/autotune';
export {
  BOOTSTRAP_DNS_SERVER_OPTIONS,
  DEFAULT_LATENCY_TEST_URL,
  DNS_SERVER_OPTIONS,
  DOMAIN_LIST_OPTIONS,
  domainListLabel,
  SECONDARY_RULESET_OPTIONS,
  LATENCY_TEST_URL_OPTIONS,
  PROKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT,
  PROKOP_UCI_PACKAGE,
} from './constants';
