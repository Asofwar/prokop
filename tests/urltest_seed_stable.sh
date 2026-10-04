#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/subscriptions"
cat >"$WORK_DIR/fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings", "dns_server": "1.1.1.1" },
  "section": [
    {
      ".name": "grouped",
      ".type": "section",
      "enabled": "1",
      "action": "connection",
      "subscription_urls": [ "https://example.com/group.json" ],
      "subscription_url_settings": "{\"https://example.com/group.json\":{\"user_agent\":\"Happ\"}}",
      "domain_suffix": [ "grouped.example" ]
    }
  ]
}
JSON
node -e '
const leaves = [];
for (let i = 1; i <= 12; i++)
  leaves.push({ type: "socks", tag: "node-" + i, server: "127.0.0." + i, server_port: 1080, remark: "node-" + i });
const group = { type: "urltest", tag: "Provider Group", outbounds: leaves.map((leaf) => leaf.tag),
  url: "https://www.gstatic.com/generate_204", interval: "10m", tolerance: 50,
  remark: "Provider Group", __prokop_allow_group: true };
process.stdout.write(JSON.stringify({ outbounds: [ group ].concat(leaves) }) + "\n");
' >"$WORK_DIR/subscriptions/grouped-subscription-1.json"
printf '%s' 'https://example.com/group.json' >"$WORK_DIR/subscriptions/grouped-subscription-1.url"
printf '%s' 'Happ' >"$WORK_DIR/subscriptions/grouped-subscription-1.user_agent"

generate() {
  local output="$WORK_DIR/$1/config.json"
  mkdir -p "$output.section-cache" "$output.rulesets"
  TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions" \
    PROKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent" \
    PROKOP_RUNTIME_STATE_DIR="$WORK_DIR/run" \
    ucode -L "$PROKOP_LIB" "$PROKOP_LIB/singbox/generator.uc" generate-config-fixture \
      "$WORK_DIR/fixture.json" "$output" "127.0.0.1" "0" "1" ||
    fail "$1: the config must be generated"
  md5sum <"$output" | cut -d' ' -f1
}

generate probe >/dev/null
grep -q '"type": *"urltest"' "$WORK_DIR/probe/config.json" ||
  fail "the fixture must produce a provider URLTest group"

seed_file="$WORK_DIR/run/urltest-seed"
[ -s "$seed_file" ] || fail "the generator must keep its URLTest seed under the runtime state dir"
first_seed="$(cat "$seed_file")"

reference="$(generate run-1)"
for run in 2 3 4 5 6; do
  [ "$(generate "run-$run")" = "$reference" ] ||
    fail "reload $run produced a different config: sing-box would restart for nothing"
done
[ "$(cat "$seed_file")" = "$first_seed" ] || fail "the URLTest seed must stay the same until reboot"

# A reboot clears tmpfs: a new seed is drawn and kept from then on.
rm -f "$seed_file"
generate after-reboot >/dev/null
[ -s "$seed_file" ] || fail "a new URLTest seed must be saved after a reboot"
[ "$(cat "$seed_file")" != "$first_seed" ] || fail "a reboot must draw a new URLTest seed"

# A damaged seed file is replaced rather than used.
printf 'bad seed!\n' >"$seed_file"
generate damaged >/dev/null
grep -Eq '^[A-Za-z0-9-]{8,64}$' "$seed_file" || fail "a damaged URLTest seed must be replaced"

printf 'urltest seed checks passed\n'
