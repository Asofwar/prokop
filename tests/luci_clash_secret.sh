#!/usr/bin/env bash
set -euo pipefail

# UC-035, UC-038, D-1 (b): the Clash API secret field is not tied to WAN
# access. LuCI removes an inactive (depends-hidden) option on save, so turning
# WAN access off used to erase the secret that sing-box still enforced on the
# LAN controller.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const root = process.argv[2];
const settings = fs.readFileSync(
  path.join(root, 'luci-app-prokop/htdocs/luci-static/resources/view/prokop/settings.js'), 'utf8');

const start = settings.indexOf('"yacd_secret_key"');
assert(start >= 0, 'the secret option exists');
const field = settings.slice(start, settings.indexOf('sections.', start));
assert.doesNotMatch(field, /o\.depends\(/, 'the secret must not depend on another option');
assert.match(field, /o\.password = true;/, 'the secret is a password field');
assert.match(field, /o\.rmempty = false;/, 'an empty secret is not silently removed');
console.log('Clash API secret field is independent of WAN access');
NODE
