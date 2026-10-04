import { asText } from '../../../helpers/asText';
import { ProkopShellMethods } from '../../methods';
import { prokopPageUrl, readPageParams } from '../../helpers/navigation';
import { Prokop } from '../../types';
import { renderProvenance, type Provenance } from '../../ui/status';
import {
  dpiProviderLabel,
  dpiStrategyLabel,
  pathKindLabel,
  type PathKind,
} from '../monitoring/connectionView';
import { probe, resultView, type RowResult } from './connectivityMatrix';
import type { StatusTone } from './statusLabels';

// "Check a site": one address answers "why does X not open" with the route
// the configuration assigns (calculated), the router DNS answer and a probe
// from the router (observed). Monitoring shows what real devices did.

export interface SiteRow {
  label: string;
  value: string;
  note: string;
  provenance: Provenance;
  tone: StatusTone;
}

export function undecidedReasonText(reason?: string | null) {
  switch (reason) {
    case 'singbox_config_unavailable':
    case 'config_unavailable':
      return _(
        'the sing-box configuration is not available; is Prokop running?',
      );
    // Reason codes of routing/resolve.uc (shared with autotune apply). The
    // rule may be the one that would own the site (UC-103).
    case 'undecidable_matcher':
      return _(
        'a rule on the way uses a list or pattern whose contents cannot be checked here',
      );
    case 'resolve_rule':
      return _(
        'a rule on the way re-resolves the address, so the route depends on its answer',
      );
    case 'ipv6_not_modelled':
      return _('the route of an IPv6 address is not calculated');
    case 'fakeip_domain_unknown':
      return _(
        'a FakeIP address is routed by its domain; check the site by its name',
      );
    case 'dns_hijack':
      return _(
        'connections to the DNS port are answered by the sing-box DNS, not routed by a rule',
      );
    case 'real_address_interception_unknown':
      return _(
        'the site has a real address; whether Prokop intercepts it depends on the address lists of the rules',
      );
    case 'local_address_not_intercepted':
      return _(
        'the address is local or reserved; Prokop does not intercept it, the connection goes directly',
      );
    case 'source_scoped_rule':
      return _('a rule applies to selected devices only; choose a device');
    default:
      return _('a rule is too complex to calculate');
  }
}

function kindOf(action: string): PathKind {
  if (action === 'zapret' || action === 'zapret2' || action === 'byedpi')
    return 'dpi';
  if (['connection', 'bypass', 'block', 'direct'].includes(action))
    return action as PathKind;
  return 'unknown';
}

export function routeRow(trace: Prokop.RouteTrace): SiteRow {
  const action = String(trace.action.value || '');
  if (trace.action.provenance === 'unknown' || !action)
    return {
      label: _('Route'),
      value: _('Rule not calculated'),
      note: undecidedReasonText(trace.rule.reason),
      provenance: 'unknown',
      tone: 'neutral',
    };
  const kind = kindOf(action);
  const parts = [pathKindLabel(kind)];
  if (trace.rule.value) parts.push(`${_('rule')} «${trace.rule.value}»`);
  if (kind === 'dpi')
    parts.push(
      [
        dpiProviderLabel(String(trace.dpi.value || action)),
        dpiStrategyLabel({
          name: '',
          label: '',
          action,
          dpiStrategy: trace.dpi.strategy,
          dpiCustom: trace.dpi.strategy_custom,
        }),
      ]
        .filter(Boolean)
        .join(' · '),
    );
  return {
    label: _('Route'),
    value: parts.join(' · '),
    note:
      kind === 'direct'
        ? _('No rule matched')
        : kind === 'block'
          ? _('The address is blocked by a rule')
          : '',
    provenance: 'simulated',
    tone: 'neutral',
  };
}

export function dnsRow(trace: Prokop.RouteTrace): SiteRow {
  const address = trace.dns.address || '';
  if (trace.dns.provenance === 'simulated')
    return {
      label: _('Address'),
      value: address,
      note: _('An IP address needs no DNS'),
      provenance: 'simulated',
      tone: 'neutral',
    };
  if (!address)
    return {
      label: _('DNS'),
      value: _('Not resolved'),
      note: _('The router DNS returned no address'),
      provenance: 'observed',
      tone: 'error',
    };
  return {
    label: _('DNS'),
    value: /^198\.1[89]\./.test(address) ? `${address} (FakeIP)` : address,
    note: _('Answer of the router DNS'),
    provenance: 'observed',
    tone: 'success',
  };
}

export function probeRow(result: RowResult): SiteRow {
  const view = resultView(result);
  return {
    label: _('From the router'),
    value: view.text,
    note: _('HTTPS request made by the router itself'),
    provenance: result.state === 'done' ? 'observed' : 'unknown',
    tone: view.tone,
  };
}

// A conclusion never claims more than the router could establish.
export function siteConclusion(trace: Prokop.RouteTrace, result: RowResult) {
  const action = String(trace.action.value || '');
  if (!trace.dns.address)
    return _(
      'The name does not resolve on the router, so no rule can open it. Check the DNS results above.',
    );
  if (action === 'block')
    return _(
      'A rule blocks this address. This is intended for ads and trackers.',
    );
  // Without an observed answer nothing is known about the site.
  if (result.state !== 'done' || result.result.error === 'tool_missing')
    return _(
      'The router could not check whether the site opens. Try the check again.',
    );
  if (result.result.status === 'ok')
    return _(
      'The site opens from the router. If it does not open on a device, look at its real connections.',
    );
  const hint =
    kindOf(action) === 'dpi'
      ? _(
          'For a DPI rule this can mean the strategy does not work with your provider.',
        )
      : action === 'connection'
        ? _('Check the node of the rule in Monitoring → Nodes and groups.')
        : action === 'direct'
          ? _('No rule handles it; it may need to be added to a rule.')
          : '';
  return [
    _(
      'The site did not open from the router. The router may take a different path than devices.',
    ),
    hint,
  ]
    .filter(Boolean)
    .join(' ');
}

function renderRow(row: SiteRow) {
  return [
    E('dt', {}, asText(row.label)),
    E('dd', {}, [
      // Value and its provenance on one line; neutral values keep the text colour.
      E('span', { class: 'fkp-site__value' }, [
        E(
          'span',
          row.tone === 'neutral' ? {} : { class: `fkp-diag-text--${row.tone}` },
          asText(row.value),
        ),
        ' ',
        renderProvenance(row.provenance),
      ]),
      row.note ? E('small', {}, asText(row.note)) : '',
    ]),
  ];
}

// route_trace answers {error:"invalid_input"} for a target it rejects;
// anything else is a failed check, not a typing mistake.
export function routeTraceFailureText(response: {
  success: boolean;
  data?: unknown;
}) {
  const data = response.data as { error?: unknown } | undefined;
  if (response.success && data?.error === 'invalid_input') {
    return _('Enter a valid domain or IP address');
  }

  return _('The route check did not complete. Try again.');
}

export function initSiteCheck(
  loadDevices?: () => Promise<Record<string, string>>,
) {
  const button = document.getElementById(
    'site-check-run',
  ) as HTMLButtonElement | null;
  const input = document.getElementById(
    'site-check-target',
  ) as HTMLInputElement | null;
  const device = document.getElementById(
    'site-check-device',
  ) as HTMLSelectElement | null;
  const container = document.getElementById('site-check-result');
  if (!button || !input || !container || button.onclick) return;

  void loadDevices?.()
    .then((devices) => {
      if (!device) return;
      for (const [ip, name] of Object.entries(devices || {}))
        device.appendChild(
          E('option', { value: ip }, asText(`${name || ip} (${ip})`)),
        );
    })
    .catch(() => {
      /* the selector keeps "Any device" */
    });

  input.onkeydown = (event) => {
    if (event.key === 'Enter') button.click();
  };
  input.oninput = () => container.replaceChildren();

  button.onclick = async () => {
    const target = input.value.trim();
    if (!target) {
      container.textContent = _('Enter a domain or IP address');
      return;
    }
    const source = device?.value || '';
    container.textContent = _('Checking…');
    button.disabled = true;
    try {
      const [trace, reach] = await Promise.all([
        ProkopShellMethods.routeTrace(target, source, 'TCP', '443'),
        probe({ host: target, type: 'HTTPS', port: '443' }),
      ]);
      if (input.value.trim() !== target) return;
      if (!trace.success || !trace.data?.target) {
        container.textContent = routeTraceFailureText(trace);
        return;
      }
      const rows = [routeRow(trace.data), dnsRow(trace.data), probeRow(reach)];
      container.replaceChildren(
        E('dl', { class: 'fkp-route__facts' }, rows.flatMap(renderRow)),
        E(
          'p',
          { class: 'fkp-site__conclusion' },
          asText(siteConclusion(trace.data, reach)),
        ),
        E('div', { class: 'fkp-diag-actions' }, [
          E(
            'a',
            {
              class: 'btn cbi-button',
              href: prokopPageUrl('monitoring', { search: target }),
            },
            _('See connections to this address'),
          ),
        ]),
        ...(trace.data.interface.value
          ? [
              E(
                'p',
                { class: 'fkp-diag-hint' },
                asText(
                  `${_('Router kernel route')}: ${trace.data.interface.value}`,
                ),
              ),
            ]
          : []),
      );
    } catch (_error) {
      if (input.value.trim() === target)
        container.textContent = routeTraceFailureText({ success: false });
    } finally {
      button.disabled = false;
    }
  };

  // diagnostics#host=example.com (from Monitoring) only fills the field: a
  // link must not make the router contact a host without a click (UC-128).
  const host = readPageParams().host;
  if (host && !input.value) input.value = host.slice(0, 253);
}
