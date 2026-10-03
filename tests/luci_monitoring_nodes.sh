#!/usr/bin/env bash
set -euo pipefail

# Stage 6.5: node selection lives in Monitoring (monitoring#view=nodes), the
# Overview only summarizes it; Monitoring names routes and DPI strategies from
# the derived read-only section view, never from raw strategy options.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const root = process.argv[2];
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const src = 'fe-app-prokop/src/prokop/tabs/';

const dashboardRender = read(src + 'dashboard/render.ts');
const overview = dashboardRender.slice(0, dashboardRender.indexOf('export function renderNodes'));
assert.doesNotMatch(overview, /dashboard-sections-grid/, 'Overview must not host node selection');
assert.match(dashboardRender.slice(dashboardRender.indexOf('export function renderNodes')), /dashboard-sections-grid/,
  'the Nodes view renders the node selection grid');

const monitoringRender = read(src + 'monitoring/render.ts');
assert.match(monitoringRender, /renderNodes\(\)/, 'Monitoring hosts the Nodes view');
const page = read('luci-app-prokop/htdocs/luci-static/resources/view/prokop/page/monitoring.js');
assert.match(page, /main\.DashboardTab\.initController\(\)/, 'the monitoring page starts the node selection controller');

const cards = read(src + 'dashboard/overviewCards.ts');
assert.match(cards, /openProkopPage\('monitoring', \{ view: 'nodes' \}\)/, 'Overview links to Monitoring → Nodes');

const monitoring = read(src + 'monitoring/initController.ts');
assert.match(monitoring, /ProkopShellMethods\.getReadonlyConfigSections\(\)/,
  'Monitoring reads the derived section view for both roles');
assert.doesNotMatch(monitoring, /nfqws2?_opt|byedpi_cmd_opts/, 'Monitoring never shows raw strategy options');
assert.doesNotMatch(monitoring, /fkp-monitoring-trace/, 'the fake per-row trace action is gone');
assert.match(monitoring, /renderProvenance\('observed'\)/, 'the route is marked as observed');
assert.match(monitoring, /renderProvenance\('configured'\)/, 'the DPI strategy is marked as from configuration');

console.log('Monitoring hosts node selection and names paths safely');
NODE
