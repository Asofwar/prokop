#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIAGNOSTICS="$ROOT_DIR/prokop/files/usr/lib/diagnostics/status.uc"
DIAGNOSTICS_RUNTIME="$ROOT_DIR/prokop/files/usr/lib/diagnostics/runtime.uc"
PROKOP_BIN="$ROOT_DIR/prokop/files/usr/bin/prokop"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
CLI_UC="$PROKOP_BIN"
WORK_DIR="$(mktemp -d)"

status_ucode() {
  ucode -L "$PROKOP_LIB" "$DIAGNOSTICS" "$@"
}

# The modes of diagnostics/status.uc that nothing ran (service-status-json,
# the server exposure and firewall checks, public-host-flags, ...) are gone
# (UC-179); diagnostics/runtime.uc is its only caller.
for mode in service-status-json server-listen-requires-firewall firewall-required-protocols-open \
  public-host-flags server-required-ports-listening server-required-port-conflict-owners; do
  if status_ucode "$mode" >/dev/null 2>&1 </dev/null; then
    printf 'FAIL: diagnostics/status.uc still runs %s\n' "$mode" >&2
    exit 1
  fi
done

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ ! -e "$PROKOP_LIB/status_diagnostics.sh" ] ||
  fail "status_diagnostics.sh shell owner must be removed"
grep -Fq 'get_system_info: [ "diagnostics/runtime.uc", "get-system-info", 0 ]' "$CLI_UC" ||
  fail "service/cli.uc must dispatch get_system_info through diagnostics/runtime.uc"
[ "$(PROKOP_VERSION=runtime-test ucode -L "$PROKOP_LIB" "$DIAGNOSTICS_RUNTIME" show-version)" = "runtime-test" ] ||
  fail "diagnostics/runtime.uc show-version mode failed"
if grep -n -E 'require\("uci"\)\.cursor|uci -q|uci", "show"|uci", "-q"' "$DIAGNOSTICS_RUNTIME" >/dev/null 2>&1; then
  fail "diagnostics/runtime.uc must use core.uci instead of owning direct UCI cursor or CLI calls"
fi
grep -Fq '"prokop-stably-running", RT_TABLE_NAME, NFT_TABLE_NAME, NFT_FAKEIP_MARK, RUNTIME_STABLE_MIN_AGE' "$DIAGNOSTICS_RUNTIME" ||
  fail "diagnostics Prokop status must use stable runtime state to avoid crash-loop flicker"
grep -Fq '"sing-box-service-stable",' "$DIAGNOSTICS_RUNTIME" ||
  fail "diagnostics sing-box status must use stable runtime state to avoid crash-loop flicker"

masked_config="$WORK_DIR/prokop-masked"
cat >"$masked_config" <<'EOF'
config settings 'main'
        option hwid 'device-secret'
        option proxy_string 'vless://secret@example.com:443'
config subscription_url 'sub1'
        option url 'https://user:password@example.com/subscription?token=secret'
EOF
masked_output="$(status_ucode prokop-config-masked "$masked_config")"
case "$masked_output" in
  *device-secret*|*vless://secret*|*token=secret*|*user:password*) fail "masked Prokop config leaked a secret" ;;
esac
case "$masked_output" in
  *"option hwid 'MASKED'"*) ;;
  *) fail "masked Prokop config must preserve the HWID option shape" ;;
esac
case "$masked_output" in
  *"option url 'MASKED'"*) ;;
  *) fail "masked Prokop config must mask subscription section URLs" ;;
esac

wan_wireguard="$WORK_DIR/network-wireguard"
cat >"$wan_wireguard" <<'EOF'
config interface 'wan'
        option proto 'wireguard'
        option private_key 'wireguard-private-secret'
        option addresses '192.0.2.2/32'
config interface 'lan'
        option private_key 'not-in-wan'
EOF
wan_output="$(status_ucode wan-config-masked "$wan_wireguard")"
case "$wan_output" in
  *wireguard-private-secret*) fail "masked WAN config leaked the WireGuard private key" ;;
esac
case "$wan_output" in
  *"option private_key 'MASKED'"*) ;;
  *) fail "masked WAN config must preserve a masked WireGuard private key option" ;;
esac

{
  printf 'Tue Jun 30 11:00:00 2026 user.notice prokop: [info] Starting Prokop\n'
  for i in $(seq 1 4500); do
    printf 'Tue Jun 30 11:00:%02d 2026 daemon.info unrelated[%04d]: filler filler filler filler filler filler filler filler filler filler\n' "$((i % 60))" "$i"
  done
  printf 'Tue Jun 30 11:01:00 2026 user.notice prokop: [info] large logread marker survived stdin transport\n'
} >"$WORK_DIR/large-logread.txt"
large_logs="$(PROKOP_LIB="$PROKOP_LIB" ucode -L "$PROKOP_LIB" "$DIAGNOSTICS_RUNTIME" prokop-logs-fixture <"$WORK_DIR/large-logread.txt")" ||
  fail "diagnostics/runtime.uc must process large logread payloads through stdin without shell argument limits"
case "$large_logs" in
  *"large logread marker survived stdin transport"*) ;;
  *) fail "large logread marker missing from rendered logs" ;;
esac

fake_bin="$WORK_DIR/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/curl" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
case "$*" in
  *'127.0.0.1:9090/proxies') printf '%s\n' '{"proxies":{"urltest":{"type":"URLTest"},"provider-urltest":{"type":"urltest"},"proxy-a":{"type":"VLESS"},"proxy-b":{"type":"Trojan"}}}' ;;
  *) printf '%s\n' '{"delay":1}' ;;
esac
SH
chmod +x "$fake_bin/curl"
uci_state="$WORK_DIR/uci-state.txt"
cat >"$uci_state" <<'EOF'
prokop.settings=settings
prokop.settings.latency_test_url=https://latency.example/generate_204
EOF
FAKE_CURL_LOG="$WORK_DIR/fake-curl.log" \
PROKOP_UCI_STATE_FILE="$uci_state" \
PROKOP_LIB="$PROKOP_LIB" \
PATH="$fake_bin:$PATH" \
  ucode -L "$PROKOP_LIB" "$DIAGNOSTICS_RUNTIME" clash-api get_proxy_latency proxy-out 5000 >/dev/null ||
  fail "clash-api get_proxy_latency should use fake curl successfully"
grep -Fq "url=https://latency.example/generate_204" "$WORK_DIR/fake-curl.log" ||
  fail "clash-api latency check must use settings.latency_test_url"

latency_action_dir="$WORK_DIR/ui-state/latency-actions"
mkdir -p "$latency_action_dir"
latency_state="$latency_action_dir/latency-1.json"
printf '%s\n' '{"success":true,"running":true,"kind":"latency","latency_type":"proxy_list","section":"main","tag":"[]","started_at":100}' >"$latency_state"
FAKE_CURL_LOG="$WORK_DIR/fake-curl-latencies.log" \
PROKOP_UCI_STATE_FILE="$uci_state" \
PROKOP_LIB="$PROKOP_LIB" \
PROKOP_UI_LATENCY_ACTION_DIR="$latency_action_dir" \
PATH="$fake_bin:$PATH" \
  ucode -L "$PROKOP_LIB" "$DIAGNOSTICS_RUNTIME" clash-api get_proxy_latencies '["urltest","proxy-a","provider-urltest","proxy-b"]' 5000 "$latency_state" >/dev/null ||
  fail "clash-api get_proxy_latencies should update latency progress"
JOB_STATE="$latency_state" node - <<'NODE'
const fs = require("fs");
const value = JSON.parse(fs.readFileSync(process.env.JOB_STATE, "utf8"));
if (!value.progress || value.progress.completed !== 4 || value.progress.total !== 4 || value.progress.failed !== 0) {
  console.error("latency progress after proxy list mismatch");
  process.exit(1);
}
NODE
expected_latency_paths=(
  '/proxies/proxy-a/delay'
  '/proxies/proxy-b/delay'
  '/group/urltest/delay'
  '/group/provider-urltest/delay'
)
for index in "${!expected_latency_paths[@]}"; do
  sed -n "$((index + 2))p" "$WORK_DIR/fake-curl-latencies.log" |
    grep -Fq "${expected_latency_paths[$index]}" ||
    fail "bulk latency must test ordinary proxies before URLTest groups"
done

# This test exercises API dispatch, not host process discovery. Model one
# ready managed sing-box instance; real lock ownership is covered separately.
mkdir -p "$WORK_DIR/latency-lib/service"
ln -s "$PROKOP_LIB/core" "$WORK_DIR/latency-lib/core"
ln -s "$PROKOP_LIB/diagnostics" "$WORK_DIR/latency-lib/diagnostics"
cat >"$WORK_DIR/latency-lib/service/state.uc" <<'UC'
if (ARGV[0] == "sing-box-service-runtime-pid") {
    print("4242\n");
    exit(0);
}
if (ARGV[0] == "single-ready-sing-box-runtime" ||
    ARGV[0] == "acquire-runtime-dir-lock" ||
    ARGV[0] == "acquire-runtime-dir-lock-wait" ||
    ARGV[0] == "release-runtime-dir-lock")
    exit(0);
exit(64);
UC
printf '%s\n' '{"outbounds":[{"type":"vless","tag":"proxy-a","server":"one.test"},{"type":"trojan","tag":"proxy-b","server":"two.test"}]}' >"$WORK_DIR/automatic-config.json"
printf 'prokop.settings.config_path=%s\n' "$WORK_DIR/automatic-config.json" >>"$uci_state"
automatic_signature="$(PROKOP_LIB="$PROKOP_LIB" ucode -L "$PROKOP_LIB" "$DIAGNOSTICS_RUNTIME" proxy-outbounds-signature "$WORK_DIR/automatic-config.json")"
printf '{"format":"1","signature":"%s"}\n' "$automatic_signature" >"$WORK_DIR/automatic.pending"
FAKE_CURL_LOG="$WORK_DIR/fake-curl-automatic-latencies.log" \
PROKOP_AUTOMATIC_LATENCY_PENDING_FILE="$WORK_DIR/automatic.pending" \
PROKOP_UCI_STATE_FILE="$uci_state" \
PROKOP_LIB="$WORK_DIR/latency-lib" \
PROKOP_AUTOMATIC_LATENCY_TEST_LOCK_DIR="$WORK_DIR/automatic-latency-test.lock" \
PATH="$fake_bin:$PATH" \
  ucode -L "$PROKOP_LIB" "$DIAGNOSTICS_RUNTIME" automatic-latency-test >/dev/null ||
  fail "automatic latency test should test available proxy outbounds"
grep -Fq '/proxies/proxy-a/delay' "$WORK_DIR/fake-curl-automatic-latencies.log" ||
  fail "automatic latency test must include ordinary proxy outbounds"
grep -Fq '/proxies/proxy-b/delay' "$WORK_DIR/fake-curl-automatic-latencies.log" ||
  fail "automatic latency test must include every ordinary proxy outbound"
if grep -Fq '/group/urltest/delay' "$WORK_DIR/fake-curl-automatic-latencies.log" ||
  grep -Fq '/group/provider-urltest/delay' "$WORK_DIR/fake-curl-automatic-latencies.log"; then
  fail "automatic latency test must leave URLTest groups to their own scheduler"
fi

sing_box_netstat="$(cat <<'EOF'
Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name
tcp        0      0 127.0.0.42:53           0.0.0.0:*               LISTEN      16244/sing-box
tcp        0      0 0.0.0.0:1602            0.0.0.0:*               LISTEN      16244/sing-box
tcp        0      0 ::1:1602                :::*                    LISTEN      16244/sing-box
udp        0      0 127.0.0.42:53           0.0.0.0:*                           16244/sing-box
udp        0      0 0.0.0.0:1602            0.0.0.0:*                           16244/sing-box
udp        0      0 ::1:1602                :::*                                16244/sing-box
EOF
)"

printf '%s\n' "$sing_box_netstat" |
  PROKOP_LIB="$PROKOP_LIB" ucode -L "$PROKOP_LIB" "$DIAGNOSTICS_RUNTIME" sing-box-standard-ports-listening-fixture >/dev/null ||
  fail "sing-box standard listeners should satisfy diagnostics"
if printf '%s\n' "$sing_box_netstat" | sed '/0.0.0.0:1602/d' |
  PROKOP_LIB="$PROKOP_LIB" ucode -L "$PROKOP_LIB" "$DIAGNOSTICS_RUNTIME" sing-box-standard-ports-listening-fixture >/dev/null 2>&1; then
  fail "missing sing-box tproxy listener should fail diagnostics"
fi

printf 'diagnostics status checks passed\n'
