#!/usr/bin/env bash
# The VPN kill-switch policy never outlives the package that can lift it
# (UC-191), checked with the real nft.
#
# The production sync renders the policy from a real live ProkopTable, checks
# (-c) and applies (-f) it, and saves it for the boots to come. A "boot" here
# is what fw4 does at every boot and firewall reload: its own table plus every
# file in ruleset-post. With the Prokop package installed the saved policy
# comes back after the boot; once the package is gone (removal, a downgrade
# to a release without the kill-switch, a sysupgrade to an image without
# Prokop) nothing may load it, and no DNS block list may stay attached.
#
# The namespace part is skipped only when such a namespace cannot be created.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
KS_UC="$PROKOP_LIB/killswitch/runtime.uc"
NFT_UC="$PROKOP_LIB/nft/apply.uc"
DNS_UC="$PROKOP_LIB/dns/apply.uc"
LOADER_SOURCE="$ROOT_DIR/prokop/files/usr/share/nftables.d/ruleset-post/90-prokop-killswitch-loader.nft"
KEEP_LIST="$ROOT_DIR/prokop/files/lib/upgrade/keep.d/prokop-killswitch"
NAMESPACE=(unshare --user --map-root-user --net --mount)

namespaces() { printf '%s %s' "$(readlink /proc/self/ns/net)" "$(readlink /proc/self/ns/mnt)"; }

if [ "${1:-}" != "--in-namespace" ]; then
  skip() {
    printf 'SKIP: killswitch_owner_nft_real: %s\n' "$1"
    exit 0
  }
  command -v nft >/dev/null 2>&1 || skip 'nft is not installed'
  command -v unshare >/dev/null 2>&1 || skip 'unshare is not installed'
  if ! probe="$("${NAMESPACE[@]}" nft list ruleset 2>&1)"; then
    skip "nftables is unavailable in an unprivileged network namespace: $probe"
  fi
  PROKOP_NFT_REAL_HOST_NAMESPACES="$(namespaces)" exec "${NAMESPACE[@]}" bash "$0" --in-namespace
fi

# ---- inside the namespace (same guard as tests/nft_real.sh) -----------------

refuse() {
  printf 'FAIL: --in-namespace is only for the private namespace this test creates (%s)\n' "$1" >&2
  exit 1
}
mapfile -t uid_map </proc/self/uid_map
read -r map_inside _ map_count <<<"${uid_map[0]:-}"
if [ "${#uid_map[@]}" != 1 ] || [ "$map_inside" != 0 ] || [ "$map_count" != 1 ]; then
  refuse "not a user namespace mapping only root: ${uid_map[*]:-}"
fi
read -r host_net host_mnt <<<"${PROKOP_NFT_REAL_HOST_NAMESPACES:-}"
read -r own_net own_mnt <<<"$(namespaces)"
if [ -z "${host_net:-}" ] || [ "$own_net" = "$host_net" ] || [ "$own_mnt" = "${host_mnt:-}" ]; then
  refuse "the network or mount namespace is not new"
fi
[ -z "$(nft list ruleset)" ] || refuse "the namespace does not start with an empty ruleset"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'live ruleset:\n' >&2
  nft list ruleset >&2 2>/dev/null || true
  printf 'logger:\n' >&2
  cat "$WORK_DIR/logger.log" >&2 2>/dev/null || true
  exit 1
}
ok() { printf 'ok - %s\n' "$1"; }

# The router's file system: /etc/... of the router is $ROOT/etc/... here.
ROOT="$WORK_DIR/root"
RULESET_POST="$ROOT/usr/share/nftables.d/ruleset-post"
STATE_DIR="$ROOT/etc/prokop/killswitch"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/stub" "$WORK_DIR/run" "$RULESET_POST" "$ROOT/etc/config" "$STATE_DIR"

for name in logger dnsmasq-init killswitch-init sync; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/%s.log"\n' "$WORK_DIR" "$name" >"$WORK_DIR/bin/$name"
done
# Only to learn which live sets the render reads; never on PATH otherwise.
cat >"$WORK_DIR/stub/nft" <<'EOF'
#!/bin/sh
# The live table with every set a rule section of the UCI state can have.
if [ "$1 $2" = "list table" ]; then
  printf 'table inet %s {\n' "$4"
  for section in $(sed -n 's/^prokop\.\([A-Za-z0-9_]*\)=section$/\1/p' "$PROKOP_UCI_STATE_FILE"); do
    for suffix in subnets subnets6 ip_ports ip6_ports port_subnets port_subnets6 subnet_ports udp_port_subnets udp_port_subnets6 udp_subnet_ports ports sources sources6 \
      fully_sources fully_sources6 excluded_sources excluded_sources6; do
      printf '\tset prokop_rule_%s_%s {\n\t\ttype ipv4_addr\n\t}\n' "$section" "$suffix"
    done
  done
  printf '}\n'
fi
exit 0
EOF
chmod 0755 "$WORK_DIR/bin/"* "$WORK_DIR/stub/nft"

export PATH="$WORK_DIR/bin:$PATH"
export PROKOP_LIB
export PROKOP_UCI_STATE_FILE="$ROOT/etc/config/uci.state"
export PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export PROKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock"
export KILLSWITCH_STATE_DIR="$STATE_DIR"
export KILLSWITCH_CACHE_DIR="$WORK_DIR/cache"
# The fixed paths the first kill-switch build used and the package's loader.
export KILLSWITCH_NFT_INCLUDE="$RULESET_POST/90-prokop-killswitch.nft"
export KILLSWITCH_NFT_LOADER="$RULESET_POST/90-prokop-killswitch-loader.nft"
export DNSMASQ_INIT="$WORK_DIR/bin/dnsmasq-init"
export PROKOP_KILLSWITCH_INIT="$WORK_DIR/bin/killswitch-init"

cat >"$WORK_DIR/config.json" <<'JSON'
{ "route": { "rules": [
  { "action": "route", "outbound": "byp-out", "domain_suffix": [ "drive.example.com" ] },
  { "action": "route", "outbound": "main-out", "domain_suffix": [ "example.com" ] }
], "rule_set": [] } }
JSON
write_uci() {
  cat >"$PROKOP_UCI_STATE_FILE" <<EOF
prokop.settings=settings
prokop.settings.source_network_interfaces=br-lan
prokop.settings.config_path=$WORK_DIR/config.json
prokop.byp=section
prokop.byp.action=bypass
prokop.byp.ip_cidr=2.2.2.0/24
prokop.main=section
prokop.main.action=connection
prokop.main.kill_switch=1
prokop.main.ip_cidr=3.3.3.0/24
dhcp.@dnsmasq[0]=dnsmasq
dhcp.@dnsmasq[0].server=$1
EOF
}
uci_value() {
  awk -F= -v key="$2" '$1 == key { print substr($0, length($1) + 2) }' "$1"
}

ks() { ucode -L "$PROKOP_LIB" "$KS_UC" "$@"; }
ks_present() { nft list table inet ProkopKillswitch >/dev/null 2>&1; }

# Installs the package's own file into a root: the loader, as built
# (build.sh, prokop/Makefile), reading the policy from that root.
install_package_files() {
  local root="$1"
  mkdir -p "$root/usr/share/nftables.d/ruleset-post"
  [ -r "$LOADER_SOURCE" ] || return 0
  sed "s#/etc/prokop/killswitch/#$root/etc/prokop/killswitch/#g" "$LOADER_SOURCE" \
    >"$root/usr/share/nftables.d/ruleset-post/90-prokop-killswitch-loader.nft"
}
# A removal, or a downgrade to a release without the kill-switch, takes the
# package's files away and leaves what Prokop created at run time.
remove_package_files() {
  rm -f "$1/usr/share/nftables.d/ruleset-post/90-prokop-killswitch-loader.nft"
}

# A boot (or any fw4 start/reload): the kernel state is gone, fw4 loads its
# table and includes every ruleset-post file of the root.
fw4_boot() {
  local root="$1" file
  nft flush ruleset
  {
    printf 'table inet fw4\nflush table inet fw4\n'
    printf 'table inet fw4 {\n\tchain forward {\n\t\ttype filter hook forward priority 0; policy accept;\n\t}\n}\n'
    for file in "$root"/usr/share/nftables.d/ruleset-post/*.nft; do
      [ -e "$file" ] && printf 'include "%s"\n' "$file"
    done
  } >"$WORK_DIR/fw4.nft"
  nft -f "$WORK_DIR/fw4.nft" || fail "fw4 could not load its ruleset with the ruleset-post includes of $root"
}

# ---- a running Prokop with one protected section ------------------------------

write_uci 127.0.0.42
# The live ProkopTable holds every set the render reads, declared exactly as
# the render declares them.
PATH="$WORK_DIR/stub:$PATH" ucode -L "$PROKOP_LIB" "$NFT_UC" killswitch-render ProkopTable ProkopKillswitch \
  "$WORK_DIR/sets.nft" 198.18.0.0/15 fc00::/18 >/dev/null || fail "could not render the set layout"
{
  printf 'add table inet ProkopTable\n'
  grep '^add set inet ProkopKillswitch prokop_rule_' "$WORK_DIR/sets.nft" | sed 's/ ProkopKillswitch / ProkopTable /'
  printf 'add element inet ProkopTable prokop_rule_byp_subnets { 2.2.2.0/24 }\n'
  printf 'add element inet ProkopTable prokop_rule_main_subnets { 3.3.3.0/24 }\n'
} >"$WORK_DIR/live.nft"
nft -f "$WORK_DIR/live.nft" || fail "could not create the live ProkopTable"

install_package_files "$ROOT"
# nft writes a listing in many small writes: a grep -q that matched early
# would end it with SIGPIPE, which pipefail reports as a failed check, so
# every listing is read in full before it is matched.
ks sync start || fail "sync from the real live table failed"
ks_present || fail "the synced policy is not live"
grep -Fq 'counter name "ks_main" jump ks_reject' <<<"$(nft list chain inet ProkopKillswitch priority_rules)" ||
  fail "the protected section does not reject"
grep -Fq '@prokop_rule_byp_subnets return' <<<"$(nft list chain inet ProkopKillswitch priority_rules)" ||
  fail "the earlier bypass section does not keep its verdict"
grep -Fq '3.3.3.0/24' <<<"$(nft list set inet ProkopKillswitch prokop_rule_main_subnets)" ||
  fail "the live set content was not copied"
ks sync reload || fail "re-applying the same policy failed"
ok "the policy rendered from a real live table passes nft -c, -f and a re-apply"

# The watcher's switch of client DNS to the standby resolver is a batch of
# its own on the live table (tests/killswitch_standby.sh stubs nft).
if printf 'add table inet ks_probe\nadd chain inet ks_probe c { type nat hook prerouting priority -102; policy accept; }\nadd rule inet ks_probe c udp dport 53 redirect to :1\n' |
  nft -c -f - >/dev/null 2>&1; then
  ks dns-redirect on || fail "switching client DNS to the standby resolver failed"
  grep -Eq 'iifname @ks_interfaces udp dport 53 counter .*redirect to :18054' <<<"$(nft list chain inet ProkopKillswitch ks_dns)" ||
    fail "the standby redirect is not in the live table"
  ks dns-redirect off || fail "handing client DNS back failed"
  dns_chain="$(nft list chain inet ProkopKillswitch ks_dns)" || fail "the DNS chain must stay in the live table"
  if grep -q redirect <<<"$dns_chain"; then fail "the standby redirect must be gone"; fi
  ok "the standby DNS redirect passes the real nft"
else
  printf 'NOTE: this kernel has no nft redirect expression; the standby DNS redirect is not checked\n'
fi

# ---- with the package installed the policy survives a reboot ------------------

fw4_boot "$ROOT"
ks_present || fail "with Prokop installed the policy must come back after a boot"
grep -Fq 'counter name "ks_main" jump ks_reject' <<<"$(nft list chain inet ProkopKillswitch priority_rules)" ||
  fail "the policy loaded at boot does not reject protected traffic"
ok "with the package installed the saved policy is loaded at boot"

# ---- removal / downgrade: nothing loads it any more ---------------------------

remove_package_files "$ROOT"
fw4_boot "$ROOT"
if ks_present; then
  fail "without the Prokop package (removal or downgrade) fw4 must not load the kill-switch"
fi
ok "after removal or a downgrade the saved policy is inert"

install_package_files "$ROOT"
fw4_boot "$ROOT"
ks_present || fail "a reinstalled package must find the saved policy again"
ok "a reinstall brings the saved policy back"

# ---- sysupgrade: Prokop stopped, protected names are blocked ------------------

write_uci 1.1.1.1
ucode -L "$PROKOP_LIB" "$DNS_UC" killswitch-refresh || fail "DNS refresh failed"
servers="$(uci_value "$PROKOP_UCI_STATE_FILE" 'dhcp.@dnsmasq[0].serversfile')"
[ -n "$servers" ] || fail "dnsmasq must read the kill-switch servers file"
grep -Fqx 'server=/example.com/' "$servers" || fail "a stopped Prokop must block protected names"

# What sysupgrade carries into the new image: /etc/config and the keep list.
sysupgrade_root() {
  local new_root="$1" path
  rm -rf "$new_root"
  mkdir -p "$new_root/etc"
  cp -a "$ROOT/etc/config" "$new_root/etc/config"
  while IFS= read -r path; do
    case "$path" in '' | '#'*) continue ;; esac
    [ -e "$ROOT$path" ] || continue
    (cd "$ROOT" && cp -a --parents ".${path%/}" "$new_root")
  done <"$KEEP_LIST"
}

NEW_ROOT="$WORK_DIR/new-root"
sysupgrade_root "$NEW_ROOT"
fw4_boot "$NEW_ROOT"
if ks_present; then
  fail "an image without Prokop must not load the kill-switch kept by sysupgrade"
fi
kept_servers="$NEW_ROOT${servers#"$ROOT"}"
if [ -e "$kept_servers" ] && grep -q '^server=/' "$kept_servers"; then
  fail "an image without Prokop must not keep a DNS block list attached to dnsmasq"
fi
ok "a sysupgrade to an image without Prokop keeps no active policy"

install_package_files "$NEW_ROOT"
fw4_boot "$NEW_ROOT"
ks_present || fail "an image with Prokop must load the policy kept by sysupgrade"
ok "a sysupgrade to an image with Prokop keeps the protection"

printf 'killswitch_owner_nft_real: PASS\n'
