#!/usr/bin/env bash
# The rule device pickers label every device with its address: devices may
# share a name, and the stored value stays the address. Labels reach
# ui.DynamicList#addChoices as nodes with text children, never as strings
# (LuCI parses a string label as HTML; FE-12).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_DEVICES_JS="$ROOT_DIR/luci-app-prokop/htdocs/luci-static/resources/view/prokop/local_devices.js"

node - "$LOCAL_DEVICES_JS" <<'NODE'
const fs = require("fs");
const source = fs.readFileSync(process.argv[2], "utf8");

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

function same(actual, expected, message) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    fail(`${message}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
  }
}

const rendered = [];
const ui = {
  DynamicList: function (values, choices, options) {
    this.values = values;
    this.choices = choices;
    this.options = options;
    this.added = [];
    this.listeners = {};
    rendered.push(this);
    this.render = () => ({
      addEventListener: (type, listener) => {
        this.listeners[type] = listener;
      },
    });
    this.clearChoices = () => {};
    this.addChoices = (values, labels) => this.added.push({ values, labels });
  },
};
globalThis.E = (tag, attrs, children) => ({ tag, attrs, children });
const main = {
  validateIP: (ip) => ({
    valid: /^\d+\.\d+\.\d+\.\d+$/.test(ip) || /^[0-9a-f:]+$/i.test(ip),
  }),
};
const rpcHints = {
  "aa:01": { name: "OPPO-Find-N6", ipaddrs: ["192.168.1.10"] },
  "aa:02": { name: "OPPO-Find-N6", ipaddrs: ["192.168.1.9"] },
  "aa:03": { name: "OPPO-Find-N6.lan", ipv6: ["fd00::9"] },
  "aa:04": { name: "iPad", ipaddrs: ["192.168.1.50"] },
};
const rpc = {
  declare: ({ method }) => () =>
    Promise.resolve(
      {
        getHostHints: rpcHints,
        getDHCPLeases: { dhcp_leases: [] },
        dump: [{ "ipv4-address": [{ address: "192.168.1.1" }] }],
      }[method],
    ),
};
const loadModule = () =>
  new Function(
    "baseclass",
    "rpc",
    "ui",
    "main",
    source.replace(/^"(use strict|require [^"]+)";$/gm, ""),
  )({ extend: (o) => o }, rpc, ui, main);
const api = loadModule();

same(
  api.labelLocalDeviceChoices({ "192.168.1.9": "OPPO-Find-N6" }),
  { "192.168.1.9": "OPPO-Find-N6 (192.168.1.9)" },
  "label carries the address",
);

const option = {
  default: null,
  cbid: () => "cbid",
  validate: () => true,
  map: { readonly: false },
};
api
  .createLocalDeviceDynamicListWidget(option, "rule", ["192.168.1.9"])
  .then(() => {
    const widget = rendered[0];
    same(widget.values, ["192.168.1.9"], "stored value stays the address");
    same(
      widget.options.sort,
      ["192.168.1.50", "192.168.1.9", "192.168.1.10", "fd00::9"],
      "order: name, then IPv4 numerically, then IPv6",
    );
    same(
      widget.options.sort.map((ip) => widget.choices[ip]),
      [
        "iPad (192.168.1.50)",
        "OPPO-Find-N6 (192.168.1.9)",
        "OPPO-Find-N6 (192.168.1.10)",
        "OPPO-Find-N6 (fd00::9)",
      ],
      "same-name devices are told apart by address",
    );
  })
  .then(() => {
    // A fresh module: nothing cached, the list loads when it is opened.
    rendered.length = 0;
    rpcHints["aa:05"] = {
      name: "tv<img src=x onerror=alert(1)>",
      ipaddrs: ["192.168.1.60"],
    };
    return loadModule()
      .createLocalDeviceDynamicListWidget(option, "rule", [])
      .then(() => {
        const widget = rendered[0];
        widget.listeners.mousedown({
          target: { closest: (selector) => selector === ".cbi-dropdown" },
        });
        return new Promise((resolve) => setTimeout(resolve, 10)).then(
          () => widget,
        );
      });
  })
  .then((widget) => {
    same(widget.added.length, 1, "opening the list adds the choices once");
    const { values, labels } = widget.added[0];
    values.forEach((value) => {
      const label = labels[value];
      if (!label || typeof label !== "object" || !Array.isArray(label.children))
        fail(`label of ${value} is not a node: ${JSON.stringify(label)}`);
    });
    same(
      labels["192.168.1.60"].children,
      ["tv<img src=x onerror=alert(1)> (192.168.1.60)"],
      "a device name with markup stays text",
    );
    console.log("PASS: local device labels");
  })
  .catch((error) => fail(error.stack || error));
NODE
