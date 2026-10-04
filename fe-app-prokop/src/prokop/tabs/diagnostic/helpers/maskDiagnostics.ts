const MASKED_VALUE = 'MASKED';

// Keep every table and function below identical to the backend copy in
// prokop/files/usr/lib/diagnostics/status.uc (the backend masks what the
// read-only role receives; this copy serves the admin "mask values" toggle).

// Keys whose values are masked in the masked sing-box config.
export const SING_BOX_MASKED_KEYS = new Set([
  'access_key_id',
  'address',
  'advertise_routes',
  'api_token',
  'auth',
  'auth_key',
  'auth_str',
  'client_key',
  'control_url',
  'domain',
  'domain_keyword',
  'domain_regex',
  'domain_suffix',
  'email',
  'excluded_source_ip_cidr',
  'exit_node',
  'extra_headers',
  'fingerprint',
  'headers',
  'host',
  'hostname',
  'ip_cidr',
  'key',
  'key_id',
  'listen',
  'listen_port',
  'local_address',
  'mac_key',
  'obfs',
  'password',
  'path',
  'peer_public_key',
  'plugin_opts',
  'pre_shared_key',
  'private_key',
  'private_key_passphrase',
  'public_key',
  'secret',
  'secret_access_key',
  'server',
  'server_name',
  'server_port',
  'server_ports',
  'service_name',
  'short_id',
  'source_ip_cidr',
  'torrc',
  'user',
  'username',
  'uuid',
]);

// Masked UCI views: allowlist. Only these options keep their value; every
// other option or list value is replaced by MASKED, so a new secret-bearing
// option fails closed.
export const UCI_SAFE_OPTIONS = new Set([
  'action',
  'active_check_interval',
  'applied_migrations',
  'auto_hwid',
  'auto_user_agent',
  'badwan_monitored_interfaces',
  'badwan_reload_delay',
  'cache_path',
  'check_interval',
  'check_timeout',
  'community_lists',
  'component_update_check_enabled',
  'component_update_check_interval',
  'conditions_text_mode',
  'config_path',
  'config_version',
  'connection_type',
  'detect_server_country',
  'direct_proxy_enabled',
  'direct_proxy_port',
  'disable_quic',
  'dns_check_interval',
  'dns_check_timeout',
  'dns_detour_enabled',
  'dns_detour_section',
  'dns_failover_failure_threshold',
  'dns_recovery_check_interval',
  'dns_rewrite_ttl',
  'dns_strategy',
  'dns_type',
  'domain_resolver_dns_type',
  'domain_resolver_enabled',
  'dont_touch_dhcp',
  'download_components_via_proxy',
  'download_components_via_proxy_section',
  'download_lists_via_proxy',
  'download_lists_via_proxy_section',
  'download_subscriptions_via_proxy',
  'download_via_proxy_enabled',
  'download_via_proxy_section',
  'enable_badwan_interface_monitoring',
  'enable_output_network_interface',
  'enable_yacd',
  'enable_yacd_wan_access',
  'enabled',
  'exclude_countries',
  'exclude_ntp',
  'exclude_outbounds',
  'exclude_regex',
  'fastest_check_interval',
  'filter_mode',
  'group',
  'hide_detour_outbounds',
  'hide_urltest_group_outbounds',
  'idle_timeout',
  'include_countries',
  'include_outbounds',
  'include_regex',
  'include_subnets',
  'include_urltest_groups',
  'intercept_client_dns',
  'interface',
  'interfaces',
  'interrupt_exist_connections',
  'label',
  'list_update_enabled',
  'log_level',
  'mixed_proxy_auth_enabled',
  'mixed_proxy_enabled',
  'mixed_proxy_port',
  'name',
  'node_prefix',
  'order',
  'outbound_detour_enabled',
  'outbound_detour_section',
  'output_network_interface',
  'pick_fastest',
  'pin_dashboard',
  'ports',
  'prefix_nodes',
  'priority_groups',
  'proxy_config_type',
  'recovery_check_interval',
  'resolve_real_ip_for_routing',
  'rule',
  'secondary_rule_sets',
  'section',
  'show_dashboard_metadata',
  'shutdown_correctly',
  'sort_by_latency',
  'source_network_interfaces',
  'subscription_update_enabled',
  'subscription_update_interval',
  'switch_to_faster_same_priority',
  'tag',
  'tolerance',
  'torrserver_direct_enabled',
  'update_interval',
  'urltest_check_interval',
  'urltest_enabled',
  'urltest_exclude_countries',
  'urltest_filter_mode',
  'urltest_include_countries',
  'urltest_tolerance',
  'urltests',
  'user_domain_list_type',
]);

// Options that are safe only in one section type (the WAN interface of
// /etc/config/network, dnsmasq of /etc/config/dhcp).
export const UCI_SAFE_SECTION_OPTIONS: Record<string, Set<string>> = {
  interface: new Set([
    'auto',
    'defaultroute',
    'delegate',
    'demand',
    'device',
    'disabled',
    'force_link',
    'ifname',
    'ip6assign',
    'ipv6',
    'keepalive',
    'metric',
    'mtu',
    'multipath',
    'norelease',
    'peerdns',
    'proto',
    'reqaddress',
    'reqprefix',
    'type',
  ]),
  dnsmasq: new Set([
    'allservers',
    'authoritative',
    'boguspriv',
    'cachesize',
    'confdir',
    'dnsforwardmax',
    'domain',
    'domainneeded',
    'ednspacket_max',
    'expandhosts',
    'filter_a',
    'filter_aaaa',
    'filterwin2k',
    'leasefile',
    'local',
    'localise_queries',
    'localservice',
    'localuse',
    'logqueries',
    'nonegcache',
    'nonwildcard',
    'noresolv',
    'port',
    'readethers',
    'rebind_localhost',
    'rebind_protection',
    'resolvfile',
    'sequential_ip',
    'server',
    'strictorder',
  ]),
};

// URL-valued options: scheme, host and path stay visible; userinfo, query
// and fragment are masked.
export const UCI_URL_OPTIONS = new Set([
  'domain_ip_lists',
  'health_url',
  'latency_test_url',
  'local_domain_lists',
  'local_subnet_lists',
  'mirror_base_url',
  'remote_domain_lists',
  'remote_subnet_lists',
  'rule_set',
  'rule_set_with_subnets',
  'testing_url',
  'urltest_testing_url',
]);

const URL_PARTS =
  /^([A-Za-z][A-Za-z0-9+.-]*:\/\/)?([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/;
const URL_SCHEME = /^([A-Za-z][A-Za-z0-9+.-]*):\/\//;
const UCI_HEADER =
  /^[ \t]*(#[ \t#]*)?config[ \t]+([A-Za-z0-9_-]+)([ \t]+['"]?[A-Za-z0-9_-]+['"]?)?[ \t]*$/;
const UCI_OPTION =
  /^([ \t]*(#[ \t#]*)?(option|list)[ \t]+([A-Za-z0-9_-]+)[ \t]*)(.*)$/;

type Quote = "'" | '"' | null;

interface UciMaskState {
  quote: Quote;
  sectionType: string;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

// scheme://userinfo@host/path?query#fragment -> userinfo, query and fragment
// masked; with maskPath the path too.
export function maskUrlValue(value: string, maskPath = false) {
  const parts = `${value}`.match(URL_PARTS);

  if (!parts) {
    return MASKED_VALUE;
  }

  const scheme = parts[1] ?? '';
  let authority = parts[2] ?? '';
  let path = parts[3] ?? '';

  // Without a scheme, userinfo can hide in what looks like a path
  // ("//user@host", "https:/user@host").
  if (
    scheme === '' &&
    (`${value}`.startsWith('//') || `${value}`.includes('@'))
  ) {
    return MASKED_VALUE;
  }

  const at = authority.lastIndexOf('@');

  if (at >= 0) {
    authority = `${MASKED_VALUE}@${authority.slice(at + 1)}`;
  }

  if (maskPath && path !== '' && path !== '/') {
    path = `/${MASKED_VALUE}`;
  }

  return `${scheme}${authority}${path}${
    parts[4] !== undefined ? `?${MASKED_VALUE}` : ''
  }${parts[5] !== undefined ? `#${MASKED_VALUE}` : ''}`;
}

// Links other than http(s) (vless://, ss://, ...) are masked completely.
export function maskHttpUrlValue(value: string) {
  const scheme = `${value}`.match(URL_SCHEME);

  if (scheme && !['http', 'https'].includes(scheme[1].toLowerCase())) {
    return MASKED_VALUE;
  }

  return maskUrlValue(value, false);
}

// Scans UCI value text from the given quote state: the quote still open at
// the end (null when closed), the unquoted value and whether a trailing
// comment follows it.
function uciValueScan(text: string, initialQuote: Quote) {
  let quote = initialQuote;
  let value = '';
  let comment = false;

  for (let i = 0; i < text.length; i++) {
    const c = text[i];

    if (quote === "'") {
      if (c === "'") quote = null;
      else value += c;
    } else if (quote === '"') {
      if (c === '\\' && i + 1 < text.length) value += text[++i];
      else if (c === '"') quote = null;
      else value += c;
    } else if (c === "'" || c === '"') quote = c;
    else if (c === '\\' && i + 1 < text.length) value += text[++i];
    else if (c === '#') {
      comment = true;
      break;
    } else if (c !== ' ' && c !== '\t' && c !== '\r') value += c;
  }

  return { quote, value, comment };
}

function uciOptionSafe(state: UciMaskState, name: string) {
  return (
    UCI_SAFE_OPTIONS.has(name) ||
    Boolean(UCI_SAFE_SECTION_OPTIONS[state.sectionType]?.has(name))
  );
}

// The option prefix with a re-quoted value (a trailing comment is dropped).
function uciQuotedLine(prefix: string, value: string) {
  return `${prefix}'${value.replace(/'/g, "'\\''")}'`;
}

// Masks one UCI line; null for a line that is not UCI (and not the
// continuation of a masked multi-line value).
function maskUciLine(state: UciMaskState, line: string): string | null {
  const indent = line.match(/^[ \t]*/)?.[0] ?? '';

  if (state.quote !== null) {
    const closing = state.quote;
    state.quote = uciValueScan(line, state.quote).quote;
    return `${indent}${MASKED_VALUE}${state.quote === null ? closing : ''}`;
  }

  const header = line.match(UCI_HEADER);

  if (header) {
    if (header[1] === undefined) {
      state.sectionType = header[2];
    }

    return line;
  }

  const option = line.match(UCI_OPTION);

  if (option) {
    const name = option[4];
    const scan = uciValueScan(option[5], null);

    if (scan.quote === null && uciOptionSafe(state, name)) {
      return scan.comment ? uciQuotedLine(option[1], scan.value) : line;
    }

    if (scan.quote === null && UCI_URL_OPTIONS.has(name)) {
      return uciQuotedLine(option[1], maskHttpUrlValue(scan.value));
    }

    state.quote = scan.quote;
    return `${option[1]}'${MASKED_VALUE}${scan.quote === null ? "'" : ''}`;
  }

  if (/^[ \t]*$/.test(line)) {
    return line;
  }

  if (/^[ \t]*#/.test(line)) {
    return `${indent}# ${MASKED_VALUE}`;
  }

  return null;
}

// An object with an address (a WireGuard peer) also hides its port; any URL
// string keeps only scheme, host and path (links are masked whole).
export function maskSingBoxConfigValue(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map((item) => maskSingBoxConfigValue(item));
  }

  if (isRecord(value)) {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [
        key,
        SING_BOX_MASKED_KEYS.has(key) ||
        (key === 'port' &&
          value.address !== undefined &&
          value.address !== null)
          ? MASKED_VALUE
          : maskSingBoxConfigValue(item),
      ]),
    );
  }

  if (typeof value === 'string' && URL_SCHEME.test(value)) {
    return maskHttpUrlValue(value);
  }

  return value;
}

export function stringifySingBoxConfig(value: unknown) {
  return typeof value === 'string' ? value : JSON.stringify(value, null, 2);
}

export function formatMaskedSingBoxConfig(value: unknown) {
  if (typeof value === 'string') {
    try {
      return JSON.stringify(maskSingBoxConfigValue(JSON.parse(value)), null, 2);
    } catch (_error) {
      return value;
    }
  }

  return JSON.stringify(maskSingBoxConfigValue(value), null, 2);
}

const VALIDATION_HEADER = '🧪 Prokop configuration validation';
const VALIDATION_FAILED = '❌ Prokop configuration validation failed';
const SECTION_SEPARATOR = /^━+$/;

// The global check text mixes status lines with UCI files (Prokop config,
// WAN, dnsmasq); only UCI lines and their continuations are masked. The raw
// validator message quotes the rejected value, so like the backend masked
// mode only the verdict of a failed validation is kept.
export function maskGlobalCheckText(text: string = '') {
  const state: UciMaskState = { quote: null, sectionType: '' };
  let inValidation = false;
  const result: string[] = [];

  for (const line of `${text}`.split('\n')) {
    if (line === VALIDATION_HEADER) {
      inValidation = true;
      result.push(line);
      continue;
    }

    if (inValidation && !SECTION_SEPARATOR.test(line)) {
      if (line.startsWith('✅')) {
        result.push(line);
      } else if (line.startsWith('❌')) {
        result.push(VALIDATION_FAILED);
      }
      continue;
    }

    inValidation = false;
    result.push(maskUciLine(state, line) ?? line);
  }

  return result.join('\n');
}
