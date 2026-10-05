#!/usr/bin/env bash
set -euo pipefail
# 2026-10-05 audit (frontend): the component progress panels and the
# Monitoring → Devices table are LuCI modules of their own
# (component_progress.js, devices_view.js), loaded only by the pages that
# show them; main.js, which every Prokop page loads, no longer carries them.
# The modules load through LuCI's own directive scanner, and the pages pass
# their functions to the controllers in main.js.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require("fs");
const path = require("path");
const assert = require("assert/strict");
const root = process.argv[2];
const { loadClass, scanRequires, baseclass } = require(path.join(root, "tests/helpers/luci_class_loader.js"));
const viewDir = path.join(root, "luci-app-prokop/htdocs/luci-static/resources/view/prokop");
const read = (file) => fs.readFileSync(path.join(viewDir, file), "utf8");

// Globals of a LuCI page the modules use when they render.
const text = (node) => (typeof node === "string" ? node : (node.children || []).map(text).join(""));
globalThis._ = (key) => key;
globalThis.E = (tag, attrs = {}, children = []) => ({
  tag,
  attrs,
  children: Array.isArray(children) ? children : [children],
  attributes: {},
  setAttribute(name, value) { this.attributes[name] = value; },
  appendChild(child) { this.children.push(child); },
});
const document = {
  createTextNode: (value) => value,
  createElementNS: (_ns, tag) => globalThis.E(tag),
  documentElement: { lang: "en" },
};
globalThis.document = document;

const onlyBaseclass = (dep) => {
  assert.equal(dep, "baseclass", `a split module requires ${dep}: it must need nothing but baseclass`);
  return baseclass;
};

// 1. The modules: LuCI reads their directives and gets their functions.
const progress = loadClass(read("component_progress.js"), onlyBaseclass, { document });
assert.deepEqual(progress.depends, [["baseclass", "baseclass"]]);
assert.equal(typeof progress.instance.renderComponentProgress, "function");
assert.equal(typeof progress.instance.patchComponentProgress, "function");
const devices = loadClass(read("devices_view.js"), onlyBaseclass, { document });
assert.deepEqual(devices.depends, [["baseclass", "baseclass"]]);
assert.equal(typeof devices.instance.renderDevicesPanel, "function");

// The panel's times come from the clock main.js passes (the router's).
const panel = progress.instance.renderComponentProgress(
  { component: "prokop", action: "install", jobId: "1-1", running: true, startedAt: 1000, finishedAt: 0, progress: null },
  { nowSeconds: () => 1090 },
);
assert.match(text(panel), /Elapsed: 1 min 30 s/, "the elapsed time is on the clock main.js passes");
assert.equal(JSON.stringify(panel).includes('"data-fkp-progress-since":"1000"'), true);
const nodes = devices.instance.renderDevicesPanel({
  status: "stopped", since: null, offload: "unknown", full: false, totalDevices: null, shownDevices: 0,
  rows: [], showConnections() {}, startServiceActions: () => [],
});
assert.match(nodes.map(text).join(" "), /Prokop service is stopped/);

// 2. The pages load them and hand them to the controllers in main.js.
const view = { extend: (properties) => baseclass.extend(properties) };
let monitoringDependencies = null;
let updatesDependencies = null;
const main = {
  DashboardTab: { initController() {} },
  MonitoringTab: { initController(deps) { monitoringDependencies = deps; }, render: () => "monitoring" },
  UpdatesTab: { initController(deps) { updatesDependencies = deps; }, render: () => "updates" },
};
const modules = {
  view,
  baseclass,
  form: { DummyValue: "DummyValue" },
  ui: {}, uci: {}, fs: {},
  "view.prokop.main": main,
  "view.prokop.shell": { renderPage: (_title, node) => node },
  "view.prokop.local_devices": { loadLocalDeviceChoices() {}, loadLocalDeviceHosts() {} },
  "view.prokop.devices_view": devices.instance,
  "view.prokop.component_progress": progress.instance,
};
const resolve = (dep) => {
  assert.ok(dep in modules, `no stub for ${dep}`);
  return modules[dep];
};

const monitoringPage = loadClass(read("page/monitoring.js"), resolve, { document });
assert.ok(monitoringPage.depends.some(([dep]) => dep === "view.prokop.devices_view"));
monitoringPage.instance.render();
assert.equal(monitoringDependencies.renderDevicesPanel, devices.instance.renderDevicesPanel,
  "the Monitoring page passes the Devices table to the controller");

const updates = loadClass(read("updates.js"), resolve, { document });
assert.ok(updates.depends.some(([dep]) => dep === "view.prokop.component_progress"));
let option = null;
updates.instance.createUpdatesContent({ option: () => (option = {}) });
option.cfgvalue();
assert.equal(updatesDependencies.renderComponentProgress, progress.instance.renderComponentProgress);
assert.equal(updatesDependencies.patchComponentProgress, progress.instance.patchComponentProgress);

// The other pages do not load them.
for (const page of fs.readdirSync(path.join(viewDir, "page"))) {
  if (page === "monitoring.js") continue;
  const deps = scanRequires(read(`page/${page}`)).map(([dep]) => dep);
  assert.ok(!deps.includes("view.prokop.devices_view"), `${page} loads devices_view`);
}

// 3. main.js does not carry them any more, and still reads as LuCI reads it.
const mainSource = read("main.js");
for (const marker of ["data-fkp-progress-since", "Restoring after the failure", "Show connections of this device"])
  assert.ok(!mainSource.includes(marker), `main.js still carries ${marker}`);
assert.deepEqual(scanRequires(mainSource).map(([dep]) => dep), ["baseclass", "fs", "uci", "ui"]);
console.log("luci_split_modules: OK");
NODE
