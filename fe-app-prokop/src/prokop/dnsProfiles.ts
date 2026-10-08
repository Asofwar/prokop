export const DNS_PROFILES = [
  {
    id: 'cloudflare_udp',
    label: 'Cloudflare · UDP',
    protocol: 'udp',
    server: '1.1.1.1',
  },
  {
    id: 'cloudflare_doh',
    label: 'Cloudflare · DoH',
    protocol: 'doh',
    server: 'cloudflare-dns.com/dns-query',
  },
  {
    id: 'cloudflare_dot',
    label: 'Cloudflare · DoT',
    protocol: 'dot',
    server: 'one.one.one.one',
  },
  {
    id: 'google_doh',
    label: 'Google · DoH',
    protocol: 'doh',
    server: 'dns.google/dns-query',
  },
  {
    id: 'google_dot',
    label: 'Google · DoT',
    protocol: 'dot',
    server: 'dns.google',
  },
  {
    id: 'quad9_doh',
    label: 'Quad9 · DoH',
    protocol: 'doh',
    server: 'dns.quad9.net/dns-query',
  },
  {
    id: 'quad9_dot',
    label: 'Quad9 · DoT',
    protocol: 'dot',
    server: 'dns.quad9.net',
  },
  {
    id: 'adguard_doh',
    label: 'AdGuard · DoH',
    protocol: 'doh',
    server: 'dns.adguard-dns.com/dns-query',
  },
  {
    id: 'adguard_doq',
    label: 'AdGuard · DoQ',
    protocol: 'doq',
    server: 'dns.adguard-dns.com',
  },
  {
    id: 'yandex_udp',
    label: 'Яндекс · UDP',
    protocol: 'udp',
    server: '77.88.8.8',
  },
  {
    id: 'yandex_doh',
    label: 'Яндекс · DoH',
    protocol: 'doh',
    server: 'common.dot.dns.yandex.net/dns-query',
  },
  {
    id: 'yandex_dot',
    label: 'Яндекс · DoT',
    protocol: 'dot',
    server: 'common.dot.dns.yandex.net',
  },
  {
    id: 'xbox_doh',
    label: 'Xbox DNS · DoH',
    protocol: 'doh',
    server: 'xbox-dns.ru/dns-query',
  },
  {
    id: 'xbox_dot',
    label: 'Xbox DNS · DoT',
    protocol: 'dot',
    server: 'xbox-dns.ru',
  },
] as const;

interface Widget {
  setValue(value: unknown): void;
}
interface Option {
  option: string;
  map?: { checkDepends?(): void };
  default?: string;
  modalonly?: boolean;
  onchange?: (event: Event, section: string, value: string) => void;
  cfgvalue?: (section: string) => unknown;
  write?: () => void;
  value(key: string, label: string): void;
  formvalue(section: string): unknown;
  getUIElement(section: string): Widget | null;
  depends(key: string, value: string): void;
}
interface Section {
  option(kind: unknown, name: string, label: string): Option;
  taboption(tab: string, kind: unknown, name: string, label: string): Option;
}

// The profile picker writes existing fields; it is never persisted as a second
// source of truth. Custom addresses are remembered separately per protocol for
// the lifetime of the form, without storing DNS credentials in browser storage.
export function attachDnsProfiles(
  section: Section,
  protocol: Option,
  server: Option,
  form: { ListValue: unknown },
  tab?: string,
) {
  const picker = tab
    ? section.taboption(tab, form.ListValue, '_dns_profile', _('DNS profile'))
    : section.option(form.ListValue, '_dns_profile', _('DNS profile'));
  picker.value('custom', _('Custom DNS'));
  DNS_PROFILES.forEach((p) => picker.value(p.id, p.label));
  picker.write = () => {};
  picker.cfgvalue = (id) => {
    const configured = server.cfgvalue?.(id);
    const address = Array.isArray(configured)
      ? configured.length === 1
        ? configured[0]
        : undefined
      : configured;
    return (
      DNS_PROFILES.find(
        (p) => p.protocol === protocol.cfgvalue?.(id) && p.server === address,
      )?.id || 'custom'
    );
  };
  if (tab) {
    picker.depends('action', 'dns');
    picker.modalonly = true;
  }
  const remembered = new Map<string, Map<string, unknown>>();
  const selected = new Map<string, string>();
  const appliedPreset = new Map<string, unknown>();
  function rememberCustom(id: string, previous: string) {
    const current = server.formvalue(id);
    // Preset-to-preset transitions must not overwrite the user's custom DNS.
    // An edited preset, however, is a custom value worth preserving.
    if (
      appliedPreset.has(id) &&
      JSON.stringify(current) === JSON.stringify(appliedPreset.get(id))
    )
      return;
    if (!remembered.has(id)) remembered.set(id, new Map());
    remembered.get(id)?.set(previous, current);
  }
  picker.onchange = (_event, id, value) => {
    const profile = DNS_PROFILES.find((p) => p.id === value);
    if (!profile) {
      const current =
        selected.get(id) ||
        String(protocol.formvalue(id) || protocol.cfgvalue?.(id) || 'udp');
      const saved = remembered.get(id)?.get(current);
      if (saved != null) server.getUIElement(id)?.setValue(saved);
      appliedPreset.delete(id);
      return;
    }
    const previous =
      selected.get(id) ||
      String(protocol.formvalue(id) || protocol.cfgvalue?.(id) || 'udp');
    rememberCustom(id, previous);
    protocol.getUIElement(id)?.setValue(profile.protocol);
    const presetValue = tab ? profile.server : [profile.server];
    server.getUIElement(id)?.setValue(presetValue);
    appliedPreset.set(id, presetValue);
    selected.set(id, profile.protocol);
    protocol.map?.checkDepends?.();
  };
  const previousChange = protocol.onchange;
  protocol.onchange = (event, id, value) => {
    const previous =
      selected.get(id) || String(protocol.cfgvalue?.(id) || 'udp');
    rememberCustom(id, previous);
    const memory = remembered.get(id)!;
    appliedPreset.delete(id);
    const fallback = DNS_PROFILES.find((p) => p.protocol === value)?.server;
    server
      .getUIElement(id)
      ?.setValue(
        memory.has(value)
          ? memory.get(value)
          : tab
            ? fallback || ''
            : [fallback || ''],
      );
    selected.set(id, value);
    picker.getUIElement(id)?.setValue('custom');
    previousChange?.(event, id, value);
  };
}
