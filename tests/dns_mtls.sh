#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

ucode -L "$PROKOP_LIB" -e '
let fs = require("fs");
let dns = require("singbox.dns");
function assert(value, message) { if (!value) { warn("FAIL: ", message, "\n"); exit(1); } }
function clone(value) { return json(sprintf("%J", value)); }
function tagged(config, tag) { for (let server in config.servers) if (server.tag == tag) return server; return null; }
let settings = {
    ".name": "settings", ".type": "settings",
    yacd_secret_key: "test-secret",
    dns_type: "doh",
    dns_server: [ "https://MEDIA.example.com:8443/private-dns", "other.example.com/dns-query", "media.example.com.evil.test/dns-query" ],
    bootstrap_dns_server: [ "media.example.com", "8.8.8.8" ],
    dns_mtls_enabled: "1",
    dns_mtls_host: "media.EXAMPLE.com",
    dns_mtls_client_certificate: "/etc/prokop/dns/client.crt",
    dns_mtls_client_key: "/etc/prokop/dns/client.key"
};
assert(dns.mtls_validation_error(settings) == "", "case-insensitive configured hostname must validate");
let config = dns.config(settings, {});
let main = tagged(config, "dns-server");
assert(main.type == "https" && main.server_port == 8443 && main.path == "/private-dns", "DoH endpoint must be preserved");
assert(main.tls.enabled && main.tls.server_name == settings.dns_mtls_host, "main DoH TLS identity");
assert(main.tls.client_certificate_path == settings.dns_mtls_client_certificate && main.tls.client_key_path == settings.dns_mtls_client_key, "main DoH client paths");
assert(sprintf("%J", tagged(config, "dns-health-main-1-server").tls) == sprintf("%J", main.tls), "matching main health check needs same client TLS");
for (let tag in [ "dns-health-main-2-server", "dns-health-main-3-server", "bootstrap-dns-server", "dns-health-bootstrap-1-server", "dns-health-bootstrap-2-server" ])
    assert(tagged(config, tag).tls == null, "unrelated or bootstrap server must not use client TLS: " + tag);
let switched = dns.state_template(settings);
switched.main_index = 1;
assert(tagged(dns.config(settings, switched), "dns-server").tls == null, "failover to unrelated main must not carry client TLS");
assert(dns.server_from_options("rule", "doh", "media.example.com/dns-query", "").tls == null, "independent DNS rule without settings retains legacy behavior");

function write_fixture(name, cfg) {
    fs.writefile(ARGV[0] + "/" + name + ".json", sprintf("%J", {
        settings: cfg,
        section: [{ ".name": "direct", ".type": "section", enabled: "1", action: "bypass", domain_suffix: [ "example.org" ] }]
    }));
}
write_fixture("valid", settings);
let disabled = clone(settings);
disabled.dns_mtls_enabled = "0";
disabled.dns_mtls_client_key = "";
assert(dns.mtls_validation_error(disabled) == "", "disabled incomplete mTLS must validate");
for (let server in dns.config(disabled, {}).servers)
    assert(server.tls == null, "disabled mTLS must not produce TLS configuration");
let legacy = clone(disabled);
for (let key in [ "dns_mtls_enabled", "dns_mtls_host", "dns_mtls_client_certificate", "dns_mtls_client_key" ])
    delete legacy[key];
assert(sprintf("%J", dns.config(disabled, {})) == sprintf("%J", dns.config(legacy, {})), "disabled mTLS must preserve legacy DNS config exactly");
write_fixture("disabled", disabled);
let changed = clone(settings);
changed.dns_mtls_client_key = "/etc/prokop/dns/new.key";
write_fixture("changed-key", changed);
changed = clone(settings);
changed.dns_mtls_client_certificate = "/etc/prokop/dns/new.crt";
write_fixture("changed-cert", changed);
changed = clone(settings);
changed.dns_mtls_host = "other.example.com";
write_fixture("changed-host", changed);
let cases = [
    { name: "missing-key", key: "dns_mtls_client_key", value: "" },
    { name: "missing-cert", key: "dns_mtls_client_certificate", value: "" },
    { name: "relative-key", key: "dns_mtls_client_key", value: "client.key" },
    { name: "relative-cert", key: "dns_mtls_client_certificate", value: "client.crt" },
    { name: "key-content", key: "dns_mtls_client_key", value: "-----BEGIN PRIVATE KEY-----\nfixture" },
    { name: "newline-path", key: "dns_mtls_client_key", value: "/etc/key\ninvalid" },
    { name: "directory-path", key: "dns_mtls_client_key", value: "/etc/" },
    { name: "missing-host", key: "dns_mtls_host", value: "" },
    { name: "wrong-host", key: "dns_mtls_host", value: "unrelated.example.com" },
    { name: "url-host", key: "dns_mtls_host", value: "https://media.example.com" },
    { name: "port-host", key: "dns_mtls_host", value: "media.example.com:443" },
    { name: "udp", key: "dns_type", value: "udp" },
    { name: "dot", key: "dns_type", value: "dot" }
];
for (let item in cases) {
    let invalid = clone(settings);
    invalid[item.key] = item.value;
    assert(dns.mtls_validation_error(invalid) != "", "invalid mTLS must be rejected: " + item.name);
    for (let server in dns.config(invalid, {}).servers)
        assert(server.tls == null, "invalid mTLS must not generate partial TLS: " + item.name);
    write_fixture("invalid-" + item.name, invalid);
}
' "$WORK_DIR"

validate() {
  PROKOP_LIB="$PROKOP_LIB" ucode -L "$PROKOP_LIB" "$PROKOP_LIB/config/validator.uc" validate-runtime-fixture "$1" '{}'
}

validate "$WORK_DIR/valid.json"
validate "$WORK_DIR/disabled.json"
for fixture in "$WORK_DIR"/invalid-*.json; do
  if validate "$fixture" >"$WORK_DIR/validation.log" 2>&1; then
    fail "invalid mTLS fixture accepted: $(basename "$fixture")"
  fi
  grep -Fq 'DNS mTLS' "$WORK_DIR/validation.log" || fail "fixture failed for an unrelated reason"
done

signature() {
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/service/state.uc" sing-box-signature-body-fixture "$1"
}
valid_signature="$(signature "$WORK_DIR/valid.json")"
[ "$valid_signature" != "$(signature "$WORK_DIR/disabled.json")" ] || fail "mTLS toggle must change reload signature"
[ "$valid_signature" != "$(signature "$WORK_DIR/changed-key.json")" ] || fail "client key path must change reload signature"
[ "$valid_signature" != "$(signature "$WORK_DIR/changed-cert.json")" ] || fail "certificate path must change reload signature"
[ "$valid_signature" != "$(signature "$WORK_DIR/changed-host.json")" ] || fail "mTLS host must change reload signature"

PROKOP_LIB="$PROKOP_LIB" PROKOP_DNS_FAILOVER_STATE_FILE="$WORK_DIR/no-state.json" \
  ucode -L "$PROKOP_LIB" "$PROKOP_LIB/singbox/generator.uc" generate-config-fixture "$WORK_DIR/valid.json" "$WORK_DIR/generated.json" 192.168.1.1 0
ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));
let count = 0;
for (let server in config.dns.servers)
    if (server.tls && server.tls.client_key_path == "/etc/prokop/dns/client.key") count++;
if (count != 2) { warn("FAIL: generated main and main-health DNS must have mTLS\n"); exit(1); }
' "$WORK_DIR/generated.json"

printf 'DNS mTLS checks passed\n'
