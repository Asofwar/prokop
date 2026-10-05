#!/usr/bin/env bash
# The rule device pickers label every device with its address: devices may
# share a name, and the stored value stays the address.
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
    rendered.push(this);
    this.render = () => ({ addEventListener() {} });
  },
};
const main = {
  validateIP: (ip) => ({
    valid: /^\d+\.\d+\.\d+\.\d+$/.test(ip) || /^[0-9a-f:]+$/i.test(ip),
  }),
};
const rpc = {
  declare: ({ method }) => () =>
    Promise.resolve(
      {
        getHostHints: {
          "aa:01": { name: "OPPO-Find-N6", ipaddrs: ["192.168.1.10"] },
          "aa:02": { name: "OPPO-Find-N6", ipaddrs: ["192.168.1.9"] },
          "aa:03": { name: "OPPO-Find-N6.lan", ipv6: ["fd00::9"] },
          "aa:04": { name: "iPad", ipaddrs: ["192.168.1.50"] },
        },
        getDHCPLeases: { dhcp_leases: [] },
        dump: [{ "ipv4-address": [{ address: "192.168.1.1" }] }],
      }[method],
    ),
};
const api = new Function(
  "baseclass",
  "rpc",
  "ui",
  "main",
  source.replace(/^"(use strict|require [^"]+)";$/gm, ""),
)({ extend: (o) => o }, rpc, ui, main);

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
    console.log("PASS: local device labels");
  })
  .catch((error) => fail(error.stack || error));
NODE
