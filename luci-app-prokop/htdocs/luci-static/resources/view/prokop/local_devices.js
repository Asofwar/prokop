"use strict";
"require baseclass";
"require rpc";
"require ui";
"require view.prokop.main as main";

const callHostHints = rpc.declare({
  object: "luci-rpc",
  method: "getHostHints",
  expect: { "": {} },
});
const callDHCPLeases = rpc.declare({
  object: "luci-rpc",
  method: "getDHCPLeases",
  expect: { "": {} },
});
const callNetworkInterfaceDump = rpc.declare({
  object: "network.interface",
  method: "dump",
  expect: { interface: [] },
});

let localDeviceChoicesCache = null;
let localDeviceHostsCache = null;
let localDeviceChoicesPromise = null;

function normalizeOptionValues(value) {
  if (!value) {
    return [];
  }

  if (Array.isArray(value)) {
    return value
      .filter(Boolean)
      .map((item) => `${item}`.trim())
      .filter(Boolean);
  }

  return `${value}`
    .split(/\s+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function normalizeLocalDeviceName(name) {
  return `${name || ""}`.trim().replace(/\.lan$/i, "");
}

function addLocalDeviceChoice(choices, ip, name) {
  const normalizedIp = `${ip || ""}`.trim();
  const normalizedName = normalizeLocalDeviceName(name);

  if (!normalizedIp || !normalizedName) {
    return;
  }

  if (!main.validateIP(normalizedIp).valid) {
    return;
  }

  choices[normalizedIp] = normalizedName;
}

function addRouterIp(routerIps, ip) {
  const normalizedIp = `${ip || ""}`.trim();

  if (!normalizedIp || !main.validateIP(normalizedIp).valid) {
    return;
  }

  routerIps[normalizedIp] = true;
}

function buildRouterIpMap(networkInterfaces) {
  const routerIps = {};

  if (!Array.isArray(networkInterfaces)) {
    return routerIps;
  }

  networkInterfaces.forEach((networkInterface) => {
    const ipAddresses = [];
    const ipv4Addresses =
      networkInterface &&
      typeof networkInterface === "object" &&
      Array.isArray(networkInterface["ipv4-address"])
        ? networkInterface["ipv4-address"]
        : [];
    const ipv6Addresses =
      networkInterface &&
      typeof networkInterface === "object" &&
      Array.isArray(networkInterface["ipv6-address"])
        ? networkInterface["ipv6-address"]
        : [];

    ipAddresses.push(...ipv4Addresses, ...ipv6Addresses);
    ipAddresses.forEach((address) => {
      addRouterIp(
        routerIps,
        address && typeof address === "object" ? address.address : address,
      );
    });
  });

  return routerIps;
}

function buildLocalDeviceChoices(hostHints, dhcpLeases, networkInterfaces) {
  const choices = {};
  const routerIps = buildRouterIpMap(networkInterfaces);

  if (hostHints && typeof hostHints === "object") {
    Object.values(hostHints).forEach((hint) => {
      if (!hint || typeof hint !== "object") {
        return;
      }

      [
        ...normalizeOptionValues(hint.ipaddrs),
        ...normalizeOptionValues(hint.ipv4),
        ...normalizeOptionValues(hint.ipv6),
      ].forEach((ip) => {
        addLocalDeviceChoice(choices, ip, hint.name);
      });
    });
  }

  if (dhcpLeases && Array.isArray(dhcpLeases.dhcp_leases)) {
    dhcpLeases.dhcp_leases.forEach((lease) => {
      if (!lease || typeof lease !== "object") {
        return;
      }

      addLocalDeviceChoice(choices, lease.ipaddr, lease.hostname);
    });
  }

  Object.keys(routerIps).forEach((ip) => {
    delete choices[ip];
  });

  return choices;
}

function normalizeMac(value) {
  return `${value || ""}`.trim().toLowerCase();
}

function addLocalDeviceHost(hosts, ip, mac, name) {
  const normalizedIp = `${ip || ""}`.trim();

  if (!normalizedIp || !main.validateIP(normalizedIp).valid) {
    return;
  }

  const previous = hosts[normalizedIp] || { name: "", mac: "" };
  hosts[normalizedIp] = {
    name: normalizeLocalDeviceName(name) || previous.name,
    mac: normalizeMac(mac) || previous.mac,
  };
}

// Address -> { name, mac }: the MAC lets Monitoring put the IPv4 and IPv6
// addresses of one device together (host hints are keyed by MAC).
function buildLocalDeviceHosts(hostHints, dhcpLeases, networkInterfaces) {
  const hosts = {};
  const routerIps = buildRouterIpMap(networkInterfaces);

  if (hostHints && typeof hostHints === "object") {
    Object.entries(hostHints).forEach(([mac, hint]) => {
      if (!hint || typeof hint !== "object") {
        return;
      }

      [
        ...normalizeOptionValues(hint.ipaddrs),
        ...normalizeOptionValues(hint.ip6addrs),
        ...normalizeOptionValues(hint.ipv4),
        ...normalizeOptionValues(hint.ipv6),
      ].forEach((ip) => {
        addLocalDeviceHost(hosts, ip, mac, hint.name);
      });
    });
  }

  if (dhcpLeases && Array.isArray(dhcpLeases.dhcp_leases)) {
    dhcpLeases.dhcp_leases.forEach((lease) => {
      if (!lease || typeof lease !== "object") {
        return;
      }

      addLocalDeviceHost(hosts, lease.ipaddr, lease.macaddr, lease.hostname);
    });
  }

  Object.keys(routerIps).forEach((ip) => {
    delete hosts[ip];
  });

  return hosts;
}

function loadLocalDeviceChoices() {
  if (localDeviceChoicesCache) {
    return Promise.resolve(localDeviceChoicesCache);
  }

  if (localDeviceChoicesPromise) {
    return localDeviceChoicesPromise;
  }

  localDeviceChoicesPromise = Promise.all([
    callHostHints().catch(() => ({})),
    callDHCPLeases().catch(() => ({})),
    callNetworkInterfaceDump().catch(() => []),
  ])
    .then(([hostHints, dhcpLeases, networkInterfaces]) => {
      localDeviceChoicesCache = buildLocalDeviceChoices(
        hostHints,
        dhcpLeases,
        networkInterfaces,
      );
      localDeviceHostsCache = buildLocalDeviceHosts(
        hostHints,
        dhcpLeases,
        networkInterfaces,
      );
      return localDeviceChoicesCache;
    })
    .finally(() => {
      localDeviceChoicesPromise = null;
    });

  return localDeviceChoicesPromise;
}

function loadLocalDeviceHosts() {
  if (localDeviceHostsCache) {
    return Promise.resolve(localDeviceHostsCache);
  }

  return loadLocalDeviceChoices().then(() => localDeviceHostsCache || {});
}

function compareLocalDeviceIps(a, b) {
  const aParts = a.split(".");
  const bParts = b.split(".");
  const aIpv4 = aParts.length === 4 && !a.includes(":");
  const bIpv4 = bParts.length === 4 && !b.includes(":");

  if (aIpv4 !== bIpv4) {
    return aIpv4 ? -1 : 1;
  }

  if (aIpv4) {
    for (let i = 0; i < 4; i += 1) {
      const diff = Number(aParts[i]) - Number(bParts[i]);
      if (diff) {
        return diff;
      }
    }
    return 0;
  }

  return a.localeCompare(b);
}

function sortLocalDeviceChoiceValues(choices) {
  return Object.keys(choices).sort((a, b) => {
    const byName = `${choices[a]}`.localeCompare(`${choices[b]}`);
    return byName || compareLocalDeviceIps(a, b);
  });
}

// The device pickers show the address next to the name: several devices may
// share a name, and the stored value is the address anyway.
function labelLocalDeviceChoices(choices) {
  const labels = {};

  Object.keys(choices || {}).forEach((ip) => {
    labels[ip] = `${choices[ip]} (${ip})`;
  });

  return labels;
}

// ui.DynamicList.addChoices hands a string label to E(), which parses it as
// HTML (FE-11, FE-12): node names come from the subscription provider and
// device names from PTR answers. Labels go in as text nodes, one per value,
// since a missing label falls back to the value, parsed the same way.
function textChoiceLabels(values, labels) {
  const nodes = {};
  values.forEach((value) => {
    const label = labels && labels[value] != null ? labels[value] : value;
    nodes[value] = E("span", {}, [`${label}`]);
  });
  return nodes;
}

function hasSingleIpValue(values) {
  return normalizeOptionValues(values).some(
    (value) => main.validateIP(value).valid,
  );
}

function preloadLocalDeviceChoicesForValues(values) {
  return hasSingleIpValue(values)
    ? loadLocalDeviceChoices()
    : Promise.resolve(null);
}

function createLocalDeviceDynamicListWidget(option, section_id, cfgvalue) {
  const values = normalizeOptionValues(
    cfgvalue != null ? cfgvalue : option.default,
  );
  const shouldResolveExistingLabels = hasSingleIpValue(values);

  return (
    shouldResolveExistingLabels ? loadLocalDeviceChoices() : Promise.resolve({})
  ).then((initialChoices) => {
    const deviceChoices = localDeviceChoicesCache || initialChoices || {};
    const choices = labelLocalDeviceChoices(deviceChoices);
    const widget = new ui.DynamicList(values, choices, {
      id: option.cbid(section_id),
      sort: sortLocalDeviceChoiceValues(deviceChoices),
      optional: option.optional || option.rmempty,
      datatype: option.datatype,
      placeholder: option.placeholder,
      validate: option.validate.bind(option, section_id),
      disabled: option.readonly != null ? option.readonly : option.map.readonly,
    });
    const node = widget.render();
    if (typeof option.onDeviceWidgetReady === "function") {
      option.onDeviceWidgetReady(section_id, widget);
    }
    if (typeof option.onDeviceListChange === "function") {
      node.addEventListener("cbi-dynlist-change", () => {
        option.onDeviceListChange(section_id, widget.getValue());
      });
    }
    let choicesLoaded = Boolean(localDeviceChoicesCache);
    let choicesLoading = false;

    const loadChoices = () => {
      if (choicesLoaded || choicesLoading) {
        return;
      }

      choicesLoading = true;
      loadLocalDeviceChoices()
        .then((loadedChoices) => {
          const labels = labelLocalDeviceChoices(loadedChoices);
          widget.clearChoices();
          const sortedValues = sortLocalDeviceChoiceValues(loadedChoices);
          widget.addChoices(
            sortedValues,
            textChoiceLabels(sortedValues, labels),
          );
          choicesLoaded = true;
        })
        .finally(() => {
          choicesLoading = false;
        });
    };

    const maybeLoadChoices = (ev) => {
      if (
        ev.target &&
        typeof ev.target.closest === "function" &&
        ev.target.closest(".cbi-dropdown")
      ) {
        loadChoices();
      }
    };

    node.addEventListener("mousedown", maybeLoadChoices, true);
    node.addEventListener("focusin", maybeLoadChoices, true);

    return node;
  });
}

const EntryPoint = {
  createLocalDeviceDynamicListWidget,
  hasSingleIpValue,
  labelLocalDeviceChoices,
  loadLocalDeviceChoices,
  loadLocalDeviceHosts,
  normalizeOptionValues,
  preloadLocalDeviceChoicesForValues,
  sortLocalDeviceChoiceValues,
};

return baseclass.extend(EntryPoint);
