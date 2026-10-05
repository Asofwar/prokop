"use strict";
"require form";
"require uci";
"require baseclass";
"require tools.widgets as widgets";
"require view.prokop.killswitch as killswitch";
"require view.prokop.main as main";

const UCI_PACKAGE = main.PROKOP_UCI_PACKAGE;

function isSingBoxDuration(value) {
  return /^(?=.*[1-9])([0-9]+(?:\.[0-9]+)?(?:ns|us|ms|s|m|h|d))+$/.test(value);
}

// D-18 (a), UC-091: automatic list updates and component update checks run
// at most once an hour; the backend runs a shorter stored interval hourly.
// A new shorter value is refused. One the configuration already holds is
// shown as it is, with a warning, and saved as 1h; an update started by
// hand always runs.
const MIN_AUTOMATIC_UPDATE_SECONDS = 3600;
const DURATION_UNIT_SECONDS = {
  ns: 1e-9,
  us: 1e-6,
  ms: 1e-3,
  s: 1,
  m: 60,
  h: 3600,
  d: 86400,
};

function isShortUpdateInterval(value) {
  const text = `${value || ""}`.trim();
  if (!isSingBoxDuration(text)) {
    return false;
  }
  let seconds = 0;
  for (const [, amount, unit] of text.matchAll(
    /([0-9]+(?:\.[0-9]+)?)(ns|us|ms|s|m|h|d)/g,
  )) {
    seconds += Number(amount) * DURATION_UNIT_SECONDS[unit];
  }
  return seconds < MIN_AUTOMATIC_UPDATE_SECONDS;
}

function setupAutomaticUpdateInterval(option, key) {
  const description = _(
    "Use sing-box duration format like 1d or 12h. Automatic updates run at most once an hour; an update started by hand always runs.",
  );
  const stored = (section_id) =>
    `${uci.get(UCI_PACKAGE, section_id, key) || ""}`.trim();

  option.placeholder = "1d";
  option.default = "1d";
  option.rmempty = false;
  // A stored interval shorter than 1h is raised even when the field is left
  // as it is.
  option.forcewrite = true;
  option.cfgvalue = function (section_id) {
    const value = stored(section_id) || "1d";
    this.description = isShortUpdateInterval(value)
      ? `${description} ${_(
          "The saved interval %s is shorter than 1h: it runs every hour, and saving the settings sets it to 1h.",
        ).format(value)}`
      : description;
    return value;
  };
  option.write = function (section_id, value) {
    const normalized = value ? `${value}`.trim() : "";
    const next = !normalized.length
      ? "1d"
      : isShortUpdateInterval(normalized)
        ? "1h"
        : normalized;

    // Compared with what the field showed: an absent option shows the
    // default 1d, and a save that leaves it is no change to write.
    if (next !== (stored(section_id) || "1d")) {
      uci.set(UCI_PACKAGE, section_id, key, next);
    }
  };
  option.validate = function (section_id, value) {
    const normalized = value ? `${value}`.trim() : "";

    if (!normalized.length || !isSingBoxDuration(normalized)) {
      return _("Use sing-box duration format like 1d or 12h");
    }
    if (
      isShortUpdateInterval(normalized) &&
      normalized !== stored(section_id)
    ) {
      return _(
        "The interval must be at least 1h: automatic updates run at most once an hour. An update started by hand always runs.",
      );
    }

    return true;
  };
}

function latencyTestUrlChoices() {
  return Array.isArray(main.LATENCY_TEST_URL_OPTIONS)
    ? main.LATENCY_TEST_URL_OPTIONS
    : [main.DEFAULT_LATENCY_TEST_URL || "https://www.gstatic.com/generate_204"];
}

function validateLatencyTestUrl(value) {
  const validation = main.validateUrl(`${value || ""}`.trim());
  return validation.valid ? true : validation.message;
}

function isDownloadSectionAction(action, capabilities) {
  switch (action) {
    case "connection":
    case "proxy":
    case "outbound":
    case "vpn":
      return true;
    case "zapret":
      return !capabilities?.loaded || Boolean(capabilities.zapretInstalled);
    case "zapret2":
      return !capabilities?.loaded || Boolean(capabilities.zapret2Installed);
    case "byedpi":
      return !capabilities?.loaded || Boolean(capabilities.byedpiInstalled);
    default:
      return false;
  }
}

// core/common.uc section_enabled(): unset is on; 1, true, yes or on in any
// letter case is on (UC-105).
function isRuleEnabled(sec) {
  const value = sec?.enabled;
  if (value === undefined || value === null) return true;
  return ["1", "true", "yes", "on"].includes(
    (Array.isArray(value) ? value.join(" ") : `${value}`).toLowerCase(),
  );
}

function isDownloadSection(sec, capabilities) {
  return (
    sec?.[".type"] === "section" &&
    isRuleEnabled(sec) &&
    isDownloadSectionAction(sec.action, capabilities)
  );
}

function refreshDownloadSectionChoices(option, capabilities) {
  const sections = option.map?.data?.state?.values?.[UCI_PACKAGE] ?? {};

  option.keylist = [];
  option.vallist = [];

  for (const secName in sections) {
    const sec = sections[secName];
    if (isDownloadSection(sec, capabilities)) {
      option.value(secName, sec.label || secName);
    }
  }
}

// The saved section stays selected when it is disabled, its DPI provider is
// not installed or it no longer exists: LuCI would otherwise show the first
// eligible rule and the next Save would re-point DNS or downloads to it. The
// kept choice is labelled and refused until the user picks another section
// (UC-008).
function describeUnavailableSection(sec, name) {
  if (!sec || sec[".type"] !== "section") {
    return {
      label: _("%s (unavailable)").format(name),
      message: _(
        "The selected section no longer exists. Choose another section.",
      ),
    };
  }

  const label = sec.label || name;
  if (!isRuleEnabled(sec)) {
    return {
      label: _("%s (disabled)").format(label),
      message: _(
        "The selected section is disabled. Enable it or choose another section.",
      ),
    };
  }

  // An enabled DPI section is left out only while its provider is missing.
  if (["zapret", "zapret2", "byedpi"].includes(sec.action)) {
    return {
      label: _("%s (provider not installed)").format(label),
      message: _(
        "The DPI provider of the selected section is not installed. Install it in Components or choose another section.",
      ),
    };
  }

  return {
    label: _("%s (unavailable)").format(label),
    message: _(
      "The selected section cannot be used here. Choose another section.",
    ),
  };
}

function keepUnavailableSectionChoice(option, value) {
  const sections = option.map?.data?.state?.values?.[UCI_PACKAGE] ?? {};

  if (!value || option.keylist.includes(value)) {
    return;
  }

  option.value(value, describeUnavailableSection(sections[value], value).label);
}

// The section as this save leaves it. uci.state.values is the config as
// loaded; uci.get adds the edits staged since then. The rules have a page of
// their own, which refuses to remove or disable a rule selected here
// (UC-199); a rules grid on this map would have its Enable checkbox parsed
// by the same save only after these fields were validated.
function currentSection(option, name) {
  const type = uci.get(UCI_PACKAGE, name, ".type");
  if (type == null) {
    return null;
  }

  // Map.lookupOption() needs the rendered page.
  const enabled = option.map?.root
    ? option.map.lookupOption("enabled", name)
    : null;
  return {
    ".type": type,
    label: uci.get(UCI_PACKAGE, name, "label"),
    action: uci.get(UCI_PACKAGE, name, "action"),
    enabled: enabled
      ? enabled[0].formvalue(enabled[1])
      : uci.get(UCI_PACKAGE, name, "enabled"),
  };
}

function configureDownloadSectionOption(option, sectionOption, capabilities) {
  option.default = "";
  option.rmempty = false;
  option.cfgvalue = function (section_id) {
    return uci.get(UCI_PACKAGE, section_id, sectionOption) || "";
  };
  option.load = function (section_id) {
    const value = this.cfgvalue(section_id);
    refreshDownloadSectionChoices(this, capabilities);
    keepUnavailableSectionChoice(this, value);
    return value;
  };
  option.write = function (section_id, value) {
    const normalized = value ? `${value}`.trim() : "";

    if (normalized) {
      uci.set(UCI_PACKAGE, section_id, sectionOption, normalized);
    } else {
      uci.unset(UCI_PACKAGE, section_id, sectionOption);
    }
  };
  option.remove = function (section_id) {
    uci.unset(UCI_PACKAGE, section_id, sectionOption);
  };
  option.validate = function (_section_id, value) {
    if (!value) {
      return _("Select a section");
    }
    // Every choice is checked as the page is now, not as it was when the
    // choices were built: Components, a tab of the same page, can install or
    // remove the provider (capabilities follow it, UC-152), and the rules
    // grid can enable, disable or remove the section (UC-008).
    const sec = currentSection(this, value);
    return isDownloadSection(sec, capabilities)
      ? true
      : describeUnavailableSection(sec, value).message;
  };
}

function configureDownloadViaProxyFlag(option, sectionOption) {
  option.default = "0";
  option.rmempty = false;
  option.write = function (section_id, value) {
    const enabled = value === "1" || value === true;
    uci.set(UCI_PACKAGE, section_id, this.option, enabled ? "1" : "0");
    if (!enabled) {
      uci.unset(UCI_PACKAGE, section_id, sectionOption);
    }
  };
}

function optionListValues(option, section_id) {
  const formValue = option.formvalue(section_id);
  const value = formValue != null ? formValue : option.cfgvalue(section_id);
  return L.toArray(value)
    .map((item) => `${item || ""}`.trim())
    .filter(Boolean);
}

function configureDnsList(
  option,
  choices,
  defaultValue,
  validate = main.validateDNS,
) {
  Object.entries(choices).forEach(([key, label]) => {
    option.value(key, _(label));
  });
  option.default = [defaultValue];
  option.placeholder = _("-- Select --");
  option.rmempty = false;
  option.validate = function (_section_id, value) {
    const normalized = `${value || ""}`.trim();
    if (!normalized) {
      return optionListValues(option, _section_id).length > 0
        ? true
        : _("Add at least one DNS server");
    }
    const validation = validate(normalized);
    return validation.valid ? true : validation.message;
  };
}

function configureDnsFailoverVisibility(option, dnsOption, bootstrapOption) {
  option.depends("dns_server", "__prokop_multiple_dns__");
  option.depends("bootstrap_dns_server", "__prokop_multiple_dns__");
  option.retain = true;
  option.checkDepends = function (section_id) {
    return (
      optionListValues(dnsOption, section_id).length > 1 ||
      optionListValues(bootstrapOption, section_id).length > 1
    );
  };
}

function configureDnsDuration(
  option,
  defaultValue,
  dnsOption,
  bootstrapOption,
) {
  option.default = defaultValue;
  option.rmempty = false;
  option.validate = function (_section_id, value) {
    const normalized = `${value || ""}`.trim();
    if (!normalized || !isSingBoxDuration(normalized)) {
      return _("Use sing-box duration format like 10s, 1m or 2m30s");
    }
    return true;
  };
  configureDnsFailoverVisibility(option, dnsOption, bootstrapOption);
}

// One tab per group of the "settings" UCI section: DNS, Network, Lists and
// updates, Service. sections: { dns, network, lists, service }.
function createSettingsContent(sections, capabilities) {
  const renderSettings = sections.dns.render;
  // Rarely changed DNS options fold under "Advanced settings".
  sections.dns.render = function () {
    return Promise.resolve(renderSettings.apply(this, arguments)).then(
      (node) => {
        const first = node.querySelector('[id$="-dns_rewrite_ttl"]');
        if (!first) return node;

        const details = E(
          "details",
          {
            class: "prokop-advanced-settings",
            style:
              "border: 1px solid var(--border-color, #555); border-radius: 4px; margin: 1em 0; padding: 0.75em;",
          },
          [
            E(
              "summary",
              {
                style: "cursor: pointer; font-weight: bold; padding: 0.25em;",
              },
              _("Advanced settings"),
            ),
          ],
        );
        first.parentNode.insertBefore(details, first);
        while (details.nextElementSibling) {
          details.appendChild(details.nextElementSibling);
        }
        // Keep invalid fields reachable even when the group was collapsed.
        details.addEventListener("validation-failure", () => {
          details.open = true;
        });
        details.addEventListener(
          "invalid",
          () => {
            details.open = true;
          },
          true,
        );
        return node;
      },
    );
  };
  let o = sections.dns.option(
    form.ListValue,
    "dns_type",
    _("DNS Protocol Type"),
    _("Select DNS protocol to use"),
  );
  o.value("doh", _("DNS over HTTPS (DoH)"));
  o.value("dot", _("DNS over TLS (DoT)"));
  o.value("udp", _("UDP (Unprotected DNS)"));
  o.default = "udp";
  o.rmempty = false;

  const dnsOption = sections.dns.option(
    form.DynamicList,
    "dns_server",
    _("DNS Servers"),
    _(
      "Main DNS server. If multiple servers are selected, a timeout switches to a backup.",
    ),
  );
  configureDnsList(dnsOption, main.DNS_SERVER_OPTIONS, "77.88.8.8");

  const bootstrapOption = sections.dns.option(
    form.DynamicList,
    "bootstrap_dns_server",
    _("Bootstrap DNS Servers"),
    _(
      "IP address of the DNS server used to resolve upstream DNS and proxies. Hostnames are not supported for Bootstrap DNS. If multiple servers are selected, a timeout switches to a backup.",
    ),
  );
  configureDnsList(
    bootstrapOption,
    main.BOOTSTRAP_DNS_SERVER_OPTIONS,
    "77.88.8.8",
    main.validateBootstrapDNS,
  );

  o = sections.dns.option(
    form.Value,
    "dns_check_interval",
    _("DNS Check Interval"),
    _("How often to check the active DNS servers."),
  );
  configureDnsDuration(o, "10s", dnsOption, bootstrapOption);

  o = sections.dns.option(
    form.Value,
    "dns_recovery_check_interval",
    _("Higher-priority DNS Check"),
    _("How often to check whether a higher-priority DNS server has recovered."),
  );
  configureDnsDuration(o, "60s", dnsOption, bootstrapOption);

  o = sections.dns.option(
    form.Value,
    "dns_check_timeout",
    _("DNS Unavailability Timeout"),
    _(
      "Maximum time to wait for example.com to resolve during a DNS health check.",
    ),
  );
  configureDnsDuration(o, "2s", dnsOption, bootstrapOption);

  o = sections.dns.option(
    form.Value,
    "dns_rewrite_ttl",
    _("DNS Rewrite TTL"),
    _("Time in seconds for DNS record caching (default: 60)"),
  );
  o.default = "60";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (!value) {
      return _("TTL value cannot be empty");
    }

    // Whole seconds only, as the router takes them (FE-9): parseInt read
    // "1.5" as 1 and "60s" as 60, which the router replaced by 60.
    if (!/^\d+$/.test(`${value}`.trim())) {
      return _("TTL must be a positive number");
    }
    if (Number(`${value}`.trim()) > 2147483647) {
      return _("TTL must be at most 2147483647 seconds");
    }

    return true;
  };

  o = sections.dns.option(form.ListValue, "dns_strategy", _("DNS Strategy"));
  o.value("prefer_ipv4", _("Prefer IPv4"));
  o.value("ipv4_only", _("IPv4 only"));
  o.value("prefer_ipv6", _("Prefer IPv6"));
  o.value("ipv6_only", _("IPv6 only"));
  o.default = "prefer_ipv4";
  o.rmempty = false;

  // C9: EDNS Client Subnet (singbox/generator.uc base_config).
  o = sections.dns.option(
    form.Value,
    "dns_client_subnet",
    _("EDNS Client Subnet"),
    _(
      "Optional. An IP address or subnet sent to the upstream DNS servers with every query, so services with servers in many places answer with ones near you. Useful when DNS goes through a proxy or a public resolver. Leave empty to send nothing",
    ),
  );
  o.placeholder = "203.0.113.0/24";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    const text = `${value || ""}`.trim();
    if (!text) {
      return true;
    }
    const ipv4 =
      /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}(\/(3[0-2]|[12]?\d))?$/;
    const ipv6 =
      /^[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*(\/(12[0-8]|1[01]\d|[1-9]?\d))?$/;
    return ipv4.test(text) || ipv6.test(text)
      ? true
      : _("Enter an IP address or subnet, such as 203.0.113.0/24");
  };

  o = sections.dns.option(
    form.Flag,
    "dns_detour_enabled",
    _("DNS through proxy"),
    _("Route main DNS requests through the selected section."),
  );
  configureDownloadViaProxyFlag(o, "dns_detour_section");

  o = sections.dns.option(
    form.ListValue,
    "dns_detour_section",
    _("DNS requests through section"),
  );
  o.depends("dns_detour_enabled", "1");
  configureDownloadSectionOption(o, "dns_detour_section", capabilities);

  o = sections.network.option(
    form.DummyValue,
    "_kill_switch_status",
    _("VPN kill-switch"),
    _(
      "Enable it per Connection section. While Prokop or the VPN is down, protected traffic is rejected instead of leaving directly; other traffic is not affected. If sing-box dies, a standby resolver keeps DNS working and blocks the names of every VPN section: large domain lists take memory on the router and time on every start and reload.",
    ),
  );
  o.rawhtml = true;
  o.write = function () {};
  o.remove = function () {};
  o.renderWidget = function () {
    return killswitch.createGlobalStatus(
      Boolean(this.map && this.map.readonly),
    );
  };

  o = sections.network.option(
    widgets.DeviceSelect,
    "source_network_interfaces",
    _("Source Network Interface"),
    _("Select the network interface from which the traffic will originate"),
  );
  o.default = "br-lan";
  o.noaliases = true;
  o.nobridges = false;
  o.noinactive = false;
  o.multiple = true;
  o.filter = function (section_id, value) {
    // Block specific interface names from being selectable
    const blocked = ["wan", "phy0-ap0", "phy1-ap0", "pppoe-wan"];
    if (blocked.includes(value)) {
      return false;
    }

    // Try to find the device object by its name
    const device = this.devices.find((dev) => dev.getName() === value);

    // If no device is found, allow the value
    if (!device) {
      return true;
    }

    // Check the type of the device
    const type = device.getType();

    // Consider any Wi-Fi / wireless / wlan device as invalid
    const isWireless =
      type === "wifi" || type === "wireless" || type.includes("wlan");

    // Allow only non-wireless devices
    return !isWireless;
  };

  o = sections.network.option(
    form.Flag,
    "enable_output_network_interface",
    _("Enable Output Network Interface"),
    _("You can select Output Network Interface, by default autodetect"),
  );
  o.default = "0";
  o.rmempty = false;

  o = sections.network.option(
    widgets.DeviceSelect,
    "output_network_interface",
    _("Output Network Interface"),
    _("Select the network interface to which the traffic will originate"),
  );
  o.noaliases = true;
  o.multiple = false;
  o.depends("enable_output_network_interface", "1");
  o.filter = function (section_id, value) {
    // Blocked interface names that should never be selectable
    const blockedInterfaces = ["br-lan"];

    // Reject immediately if the value matches any blocked interface
    if (blockedInterfaces.includes(value)) {
      return false;
    }

    // Reject lan*
    if (value.startsWith("lan")) {
      return false;
    }

    // Reject tun*, wg*, vpn*, awg*, oc*
    if (
      value.startsWith("tun") ||
      value.startsWith("wg") ||
      value.startsWith("vpn") ||
      value.startsWith("awg") ||
      value.startsWith("oc")
    ) {
      return false;
    }

    // Try to find the device object with the given name
    const device = this.devices.find((dev) => dev.getName() === value);

    // If no device is found, allow the value
    if (!device) {
      return true;
    }

    // Get the device type (e.g., "wifi", "ethernet", etc.)
    const type = device.getType();

    // Reject wireless-related devices
    const isWireless =
      type === "wifi" || type === "wireless" || type.includes("wlan");

    return !isWireless;
  };

  o = sections.network.option(
    form.Flag,
    "enable_badwan_interface_monitoring",
    _("Interface Monitoring"),
    _("Interface monitoring for Bad WAN"),
  );
  o.default = "0";
  o.rmempty = false;

  o = sections.network.option(
    widgets.NetworkSelect,
    "badwan_monitored_interfaces",
    _("Monitored Interfaces"),
    _("Select the WAN interfaces to be monitored"),
  );
  o.depends("enable_badwan_interface_monitoring", "1");
  o.multiple = true;
  o.filter = function (section_id, value) {
    // Reject if the value is in the blocked list ['lan', 'loopback']
    if (["lan", "loopback"].includes(value)) {
      return false;
    }

    // Reject if the value starts with '@' (means it's an alias/reference)
    if (value.startsWith("@")) {
      return false;
    }

    // Otherwise allow it
    return true;
  };

  o = sections.network.option(
    form.Value,
    "badwan_reload_delay",
    _("Interface Monitoring Delay"),
    _("Delay in milliseconds before reloading Prokop after interface UP"),
  );
  o.depends("enable_badwan_interface_monitoring", "1");
  o.default = "2000";
  o.rmempty = false;
  // Whole milliseconds, as service/initd.uc hands them to procd: "2s" or
  // "1.5" used to leave the interface reloads without any delay (UC-089).
  // A value saved before is left as it is (invariant 17): the backend keeps
  // a larger number and replaces any other text with the default, which
  // config/validator.uc reports. Left unchanged it is not written, so it
  // does not refuse the save of the page; an entered value is checked.
  o.validate = function (section_id, value) {
    if (!value) {
      return _("Delay value cannot be empty");
    }
    if (`${value}` === `${this.cfgvalue(section_id) ?? ""}`) {
      return true;
    }
    if (!/^[0-9]+$/.test(`${value}`) || Number(value) > 60000) {
      return _("Enter a whole number of milliseconds from 0 to 60000");
    }
    return true;
  };

  o = sections.service.option(
    form.Flag,
    "enable_yacd",
    _("Enable YACD"),
    `<a href="${main.getClashUIUrl()}" target="_blank">${main.getClashUIUrl()}</a>`,
  );
  o.default = "0";
  o.rmempty = false;

  o = sections.service.option(
    form.Flag,
    "enable_yacd_wan_access",
    _("Enable YACD WAN Access"),
    _(
      "Allows access to YACD from the WAN. Make sure to open the appropriate port in your firewall.",
    ),
  );
  o.depends("enable_yacd", "1");
  o.default = "0";
  o.rmempty = false;

  o = sections.service.option(
    form.Value,
    "yacd_secret_key",
    _("YACD Secret Key"),
    _(
      "Secret of the Clash API controller used by YACD and the Prokop pages. Required: it is generated on installation and protects the controller with or without WAN access.",
    ),
  );
  // Not tied to WAN access: an inactive option would be removed on save,
  // while sing-box keeps requiring the secret on the LAN (UC-035).
  o.password = true;
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (!value || !String(value).trim()) {
      return _("Clash API secret cannot be empty");
    }
    return true;
  };

  o = sections.network.option(
    form.Flag,
    "disable_quic",
    _("Disable QUIC"),
    _(
      "Disable the QUIC protocol to improve compatibility or fix issues with video streaming",
    ),
  );
  o.default = "1";
  o.rmempty = false;

  o = sections.lists.option(
    form.Flag,
    "list_update_enabled",
    _("Enable list updates"),
    _("Enable automatic updates for remote lists and rule sets"),
  );
  o.default = "1";
  o.rmempty = false;

  o = sections.lists.option(
    form.Value,
    "update_interval",
    _("List Update Frequency"),
  );
  o.depends("list_update_enabled", "1");
  setupAutomaticUpdateInterval(o, "update_interval");

  o = sections.lists.option(
    form.Flag,
    "component_update_check_enabled",
    _("Automatic component update checks"),
    _("Automatically check installed components for new versions"),
  );
  o.default = "0";
  o.rmempty = false;

  o = sections.lists.option(
    form.Value,
    "component_update_check_interval",
    _("Component update check interval"),
  );
  o.depends("component_update_check_enabled", "1");
  setupAutomaticUpdateInterval(o, "component_update_check_interval");

  o = sections.lists.option(
    form.Value,
    "latency_test_url",
    _("Latency test URL"),
    _(
      "Default address for checking server availability and latency. URLTest uses its own address.",
    ),
  );
  latencyTestUrlChoices().forEach((value) => o.value(value));
  o.default =
    main.DEFAULT_LATENCY_TEST_URL || "https://www.gstatic.com/generate_204";
  o.rmempty = false;
  o.validate = function (_section_id, value) {
    return validateLatencyTestUrl(value);
  };

  o = sections.lists.option(
    form.Flag,
    "download_lists_via_proxy",
    _("Download lists through a section"),
    _("Download remote lists and rule sets via the selected section"),
  );
  configureDownloadViaProxyFlag(o, "download_lists_via_proxy_section");

  o = sections.lists.option(
    form.ListValue,
    "download_lists_via_proxy_section",
    _("Download lists through"),
  );
  o.depends("download_lists_via_proxy", "1");
  configureDownloadSectionOption(
    o,
    "download_lists_via_proxy_section",
    capabilities,
  );

  o = sections.lists.option(
    form.Flag,
    "download_components_via_proxy",
    _("Download components through a section"),
    _("Download component packages via the selected section"),
  );
  configureDownloadViaProxyFlag(o, "download_components_via_proxy_section");

  o = sections.lists.option(
    form.ListValue,
    "download_components_via_proxy_section",
    _("Download components through"),
  );
  o.depends("download_components_via_proxy", "1");
  configureDownloadSectionOption(
    o,
    "download_components_via_proxy_section",
    capabilities,
  );

  o = sections.network.option(
    form.Flag,
    "dont_touch_dhcp",
    _("Dont Touch My DHCP!"),
    _("Prokop will not modify your DHCP configuration"),
  );
  o.default = "0";
  o.rmempty = false;

  o = sections.service.option(
    form.ListValue,
    "config_path",
    _("Config File Path"),
    _(
      "Select path for sing-box config file. Change this ONLY if you know what you are doing",
    ),
  );
  o.value(
    "/etc/sing-box/config.json",
    _("Flash") + " (/etc/sing-box/config.json)",
  );
  o.value(
    "/tmp/sing-box/config.json",
    _("RAM") + " (/tmp/sing-box/config.json)",
  );
  o.default = "/etc/sing-box/config.json";
  o.rmempty = false;

  o = sections.service.option(
    form.Value,
    "cache_path",
    _("Cache File Path"),
    _(
      "Select or enter path for sing-box cache file. Change this ONLY if you know what you are doing",
    ),
  );
  o.value("/tmp/sing-box/cache.db", _("RAM") + " (/tmp/sing-box/cache.db)");
  o.value(
    "/usr/share/sing-box/cache.db",
    _("Flash") + " (/usr/share/sing-box/cache.db)",
  );
  o.default = "/tmp/sing-box/cache.db";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (!value) {
      return _("Cache file path cannot be empty");
    }

    if (!value.startsWith("/")) {
      return _("Path must be absolute (start with /)");
    }

    if (!value.endsWith("cache.db")) {
      return _("Path must end with cache.db");
    }

    const parts = value.split("/").filter(Boolean);
    if (parts.length < 2) {
      return _("Path must contain at least one directory (like /tmp/cache.db)");
    }

    return true;
  };

  o = sections.service.option(
    form.ListValue,
    "log_level",
    _("Log Level"),
    _("Select the log level for sing-box"),
  );
  o.value("trace", _("Trace"));
  o.value("debug", _("Debug"));
  o.value("info", _("Info"));
  o.value("warn", _("Warning"));
  o.value("error", _("Error"));
  o.value("fatal", _("Fatal"));
  o.value("panic", _("Panic"));
  o.default = "warn";
  o.rmempty = false;

  o = sections.network.option(
    form.Flag,
    "exclude_ntp",
    _("Exclude NTP"),
    _(
      "Exclude NTP protocol traffic from the tunnel to prevent it from being routed through the proxy or VPN",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  // C14: BitTorrent goes directly (singbox/route.uc config).
  o = sections.network.option(
    form.Flag,
    "exclude_bittorrent",
    _("BitTorrent directly"),
    _(
      "BitTorrent traffic that Prokop recognises goes directly, past every rule, so a VPN or proxy provider does not block the account for torrents. Warning: it also goes past the kill-switch of a rule, so torrents of a device behind a kill-switch are not protected",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  // NET-6: plain DNS (port 53) of clients to their own servers goes to the
  // router's dnsmasq (nft/apply.uc client_dns_intercept_rules). Off by
  // default (NET-12): it catches anything on port 53.
  o = sections.network.option(
    form.ListValue,
    "intercept_client_dns",
    _("Intercept client DNS"),
    _(
      "Off by default. Devices with their own DNS server (8.8.8.8 in a TV, IoT devices) bypass domain rules and the kill-switch; when on, everything they send to port 53 of an outside server goes to the router's DNS instead. This also catches a VPN whose server uses port 53 and a DNS server in the LAN that asks outside servers itself: add their addresses to the exclusions. DNS to local addresses (Pi-hole), to the router's IPv6 prefixes and DNS over TLS stay untouched",
    ),
  );
  o.value("0", _("Never"));
  o.value("auto", _("When a rule has the kill-switch"));
  o.value("1", _("Always"));
  o.default = "0";
  o.rmempty = false;

  o = sections.network.option(
    form.DynamicList,
    "intercept_client_dns_exclude",
    _("Not intercepted"),
    _(
      "Used while client DNS is intercepted. DNS from these devices or to these servers is never intercepted: a DNS server in the LAN, the server of a VPN on port 53. An IPv4 or IPv6 address or subnet",
    ),
  );
  // Shown also while the intercept is off: a hidden option would lose its
  // list on save.
  o.placeholder = "192.168.1.53";
  o.rmempty = true;
  o.validate = function (section_id, value) {
    const text = `${value || ""}`.trim();
    if (!text) {
      return true;
    }
    const validation = main.validateSubnet(text);
    return validation.valid ? true : validation.message;
  };

  // B9: keep-alive and a shorter UDP timeout on the tproxy inbound
  // (singbox/generator.uc base_config).
  o = sections.network.option(
    form.Flag,
    "tproxy_low_memory",
    _("Low memory mode"),
    _(
      "For routers with 256 MB of memory or less and an unstable connection: sing-box finds dead client connections with keep-alive probes and ends idle UDP sessions after 60 seconds instead of 5 minutes, so they do not pile up in memory",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  // Monitoring > Devices: nft counters per LAN address
  // (diagnostics/traffic.uc), a table of their own that only counts.
  o = sections.network.option(
    form.Flag,
    "device_traffic",
    _("Count traffic per device"),
    _(
      "Counts how much each device on the source interfaces sends and receives, for Monitoring > Devices. The counters start from zero when Prokop starts",
    ),
  );
  o.default = "1";
  o.rmempty = false;
}

const EntryPoint = {
  createSettingsContent,
  // The Notifications tab (notifications.js) picks its rule the same way.
  configureDownloadSectionOption,
  configureDownloadViaProxyFlag,
};

return baseclass.extend(EntryPoint);
