#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
MIGRATION="$PROKOP_LIB/config/migration.uc"
PACKAGE_UC="$PROKOP_LIB/service/package.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'commands:\n' >&2
  cat "$WORK_DIR/commands.log" >&2 2>/dev/null || true
  printf 'uci state:\n' >&2
  cat "$WORK_DIR/uci.state" >&2 2>/dev/null || true
  exit 1
}

# 1. The global guard option becomes a per-section kill-switch.
cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "config_version": "1.0.5", "vpn_fail_closed": "1",
    "yacd_secret_key": "0123456789abcdef0123456789abcdef",
    "applied_migrations": [ "interface_sections", "enable_component_checks", "http_connection_urls",
      "flintnet_urltest_default", "retired_secondary_rulesets", "retired_secondary_rulesets_v2",
      "secondary_rulesets_mirror_v1", "own_dependency_mirror_v1", "clash_api_secret_v1", "urltest_section_names_v1" ] },
  "section": [
    { ".name": "zap", ".type": "section", "action": "zapret", "enabled": "1", "domain": [ "youtube.com" ] },
    { ".name": "main", ".type": "section", "action": "connection", "enabled": "1", "domain": [ "claude.ai" ] },
    { ".name": "legacy", ".type": "section", "action": "proxy", "domain": [ "openai.com" ] },
    { ".name": "off", ".type": "section", "action": "connection", "enabled": "0", "domain": [ "example.com" ] },
    { ".name": "byp", ".type": "section", "action": "bypass", "enabled": "1", "domain": [ "example.org" ] }
  ]
}
JSON
PROKOP_LIB="$PROKOP_LIB" ucode -L "$PROKOP_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/fixture.json" >"$WORK_DIR/out.json" ||
  fail "migration failed"
node - "$WORK_DIR/out.json" <<'JS' || fail "vpn_fail_closed migration"
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const sections = Object.fromEntries(out.config.section.map((s) => [s['.name'], s]));
const assert = (ok, message) => { if (!ok) { console.error(message); process.exit(1); } };
assert(sections.main.kill_switch === '1', 'enabled connection section must be protected');
assert(sections.legacy.kill_switch === '1', 'legacy proxy action (enabled by default) must be protected');
assert(sections.off.kill_switch === undefined, 'disabled section must stay unprotected');
assert(sections.zap.kill_switch === undefined, 'DPI section must stay unprotected');
assert(sections.byp.kill_switch === undefined, 'bypass section must stay unprotected');
assert(out.config.settings.vpn_fail_closed === undefined, 'retired option must be removed');
assert(out.config.settings.applied_migrations.includes('vpn_guard_kill_switch_v1'), 'migration must be recorded');
JS

sed -i 's/"vpn_fail_closed": "1"/"vpn_fail_closed": "0"/' "$WORK_DIR/fixture.json"
PROKOP_LIB="$PROKOP_LIB" ucode -L "$PROKOP_LIB" "$MIGRATION" migrate-fixture "$WORK_DIR/fixture.json" >"$WORK_DIR/out-off.json"
node - "$WORK_DIR/out-off.json" <<'JS' || fail "disabled guard migration"
const out = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
if (out.config.section.some((s) => s.kill_switch !== undefined)) process.exit(1);
if (out.config.settings.vpn_fail_closed !== undefined) process.exit(2);
JS

# 2. Runtime leftovers of the retired guard are removed at postinst.
ROOT="$WORK_DIR/root"
mkdir -p "$ROOT/etc/forkop/vpn-guard" "$ROOT/tmp/forkop-vpn-guard" "$ROOT/etc/init.d" "$ROOT/etc/rc.d" \
  "$ROOT/etc/hotplug.d/iface" "$ROOT/lib/upgrade/keep.d" "$ROOT/usr/share/forkop" "$WORK_DIR/bin"
printf '{"saved_offload":{"flow_offloading":"1","flow_offloading_hw":"1"}}\n' > "$ROOT/etc/forkop/vpn-guard/policy.json"
printf '{}\n' > "$ROOT/etc/forkop/vpn-guard/exceptions.json"
touch "$ROOT/tmp/forkop-vpn-guard/dns-0.conf" "$ROOT/etc/init.d/forkop-guard" "$ROOT/etc/hotplug.d/iface/95-forkop-guard" \
  "$ROOT/lib/upgrade/keep.d/forkop-guard" "$ROOT/usr/share/forkop/vpn-guard-firewall.sh" "$ROOT/etc/init.d/firewall-unrelated"
ln -s ../init.d/forkop-guard "$ROOT/etc/rc.d/S19forkop-guard"
ln -s ../init.d/forkop-guard "$ROOT/etc/rc.d/K99forkop-guard"
ln -s ../init.d/firewall-unrelated "$ROOT/etc/rc.d/S19firewall"

for command in nft ubus conntrack; do
  cat >"$WORK_DIR/bin/$command" <<SH
#!/bin/sh
printf '%s %s\n' "$command" "\$*" >> "$WORK_DIR/commands.log"
if [ "$command" = nft ] && [ "\$1 \$2" = "list table" ]; then [ -e "$WORK_DIR/guard-table" ]; exit \$?; fi
if [ "$command" = nft ] && [ "\$1" = delete ]; then rm -f "$WORK_DIR/guard-table"; fi
exit 0
SH
  chmod 0755 "$WORK_DIR/bin/$command"
done
touch "$WORK_DIR/guard-table"

cat >"$WORK_DIR/uci.state" <<'EOF'
firewall.@defaults[0]=defaults
firewall.@defaults[0].flow_offloading=0
firewall.@defaults[0].flow_offloading_hw=0
firewall.forkop_vpn_guard=include
firewall.forkop_vpn_guard.type=script
firewall.forkop_vpn_guard.path=/usr/share/forkop/vpn-guard-firewall.sh
EOF

run_cleanup() {
  PATH="$WORK_DIR/bin:$PATH" PROKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" PROKOP_LEGACY_GUARD_ROOT="$ROOT" \
    ucode -L "$PROKOP_LIB" "$PACKAGE_UC" legacy-vpn-guard-cleanup
}

run_cleanup || fail "legacy cleanup failed"
grep -Fq 'ubus call service delete { "name": "forkop-guard" }' "$WORK_DIR/commands.log" ||
  fail "the guard's procd service (standby dnsmasq, watcher) must be deleted"
grep -Fq 'nft flush chain inet ForkopVpnGuard dns' "$WORK_DIR/commands.log" || fail "the guard's DNS redirect must be removed"
if grep -Fq 'nft delete table inet ForkopVpnGuard' "$WORK_DIR/commands.log"; then
  fail "the guard's rejects must stay until the kill-switch replaces them"
fi
[ -e "$WORK_DIR/guard-table" ] || fail "guard table must stay until the first kill-switch sync"
grep -Fq 'conntrack -D -p udp --dport 53' "$WORK_DIR/commands.log" || fail "redirected DNS flows must be flushed"
grep -Fqx 'firewall.@defaults[0].flow_offloading=1' "$WORK_DIR/uci.state" || fail "saved flow offload must be restored"
grep -Fqx 'firewall.@defaults[0].flow_offloading_hw=1' "$WORK_DIR/uci.state" || fail "saved hw offload must be restored"
if grep -Fq 'forkop_vpn_guard' "$WORK_DIR/uci.state"; then fail "firewall include must be removed"; fi
for path in etc/forkop/vpn-guard tmp/forkop-vpn-guard etc/init.d/forkop-guard etc/rc.d/S19forkop-guard \
  etc/rc.d/K99forkop-guard etc/hotplug.d/iface/95-forkop-guard lib/upgrade/keep.d/forkop-guard usr/share/forkop/vpn-guard-firewall.sh; do
  [ ! -e "$ROOT/$path" ] && [ ! -L "$ROOT/$path" ] || fail "leftover $path must be removed"
done
[ -L "$ROOT/etc/rc.d/S19firewall" ] || fail "unrelated rc.d links must stay"

# Idempotent: a clean system is not touched at all.
rm -f "$WORK_DIR/guard-table"
: > "$WORK_DIR/commands.log"
run_cleanup || fail "second cleanup failed"
if grep -Eq '^(ubus|conntrack)|nft delete' "$WORK_DIR/commands.log"; then
  fail "cleanup on a clean system must not change anything"
fi

# Offload stays off when it was off before the guard.
mkdir -p "$ROOT/etc/forkop/vpn-guard"
printf '{"saved_offload":{"flow_offloading":"0"}}\n' > "$ROOT/etc/forkop/vpn-guard/policy.json"
sed -i 's/flow_offloading=1/flow_offloading=0/; s/flow_offloading_hw=1/flow_offloading_hw=0/' "$WORK_DIR/uci.state"
run_cleanup
grep -Fqx 'firewall.@defaults[0].flow_offloading=0' "$WORK_DIR/uci.state" || fail "offload that was off must stay off"

grep -Fq 'legacy_vpn_guard_cleanup();' "$PACKAGE_UC" || fail "postinst must run the legacy cleanup"

printf 'killswitch_migration: PASS\n'
