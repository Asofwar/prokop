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

mkdir -p "$WORK_DIR/bin"
# dig: answers nodeN.example with 44.0.0.N after DIG_DELAY seconds.
cat >"$WORK_DIR/bin/dig" <<'SH'
#!/bin/sh
host="" type=""
for arg in "$@"; do
  case "$arg" in
    +*|@*) ;;
    A|AAAA) type="$arg" ;;
    *) host="$arg" ;;
  esac
done
printf '%s %s\n' "$host" "$type" >>"$DIG_LOG"
[ "$type" = A ] && sleep "${DIG_DELAY:-0}"
[ "$type" = A ] || exit 0
n="${host#node}"; n="${n%%.*}"
printf 'alias.example.\n44.0.0.%s\n' "$n"
SH
cat >"$WORK_DIR/bin/nslookup" <<'SH'
#!/bin/sh
exit 1
SH
# curl: the country service answers NL for every address it is asked about.
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
out="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -d) data="$2"; shift ;;
  esac
  shift
done
printf '%s' "$data" | node -e '
const ips = JSON.parse(require("fs").readFileSync(0, "utf8"));
process.stdout.write(JSON.stringify(ips.map((ip) => ({ ip, country: "nl" }))));
' >"$out"
printf '200'
SH
chmod +x "$WORK_DIR/bin/"*

detect() {
  local count="$1"
  PATH="$WORK_DIR/bin:$PATH" DIG_LOG="$WORK_DIR/dig.log" \
    ucode -L "$PROKOP_LIB" -e '
let country = require("singbox.country");
let servers = {};
for (let i = 1; i <= int(ARGV[0]); i++)
  servers["tag-" + i] = "node" + i + ".example";
servers["literal"] = "45.0.0.1";
servers["private"] = "192.168.1.10";
printf("%J\n", country.detect(servers, {}, ""));
' "$count"
}

# 40 servers, each answer 1 s late: resolved in parallel batches, not 40 s.
: >"$WORK_DIR/dig.log"
started=$SECONDS
result="$(DIG_DELAY=1 detect 40)"
elapsed=$((SECONDS - started))
[ "$elapsed" -le 8 ] || fail "40 slow names took ${elapsed}s: they must resolve in parallel"
node -e '
const result = JSON.parse(process.argv[1]);
for (let i = 1; i <= 40; i++)
  if (result["tag-" + i] !== "NL") throw new Error("tag-" + i + " has no country: " + process.argv[1]);
if (result.literal !== "NL") throw new Error("an IP literal must be looked up as is");
if ("private" in result) throw new Error("a private address must be skipped");
' "$result" || fail "every resolved server must get its country"
grep -q '^45.0.0.1 ' "$WORK_DIR/dig.log" && fail "an IP literal must not be resolved"

# A budget smaller than one batch: lookup stops, generation goes on.
: >"$WORK_DIR/dig.log"
started=$SECONDS
PROKOP_COUNTRY_BUDGET_SECONDS=1 DIG_DELAY=2 detect 40 >"$WORK_DIR/budget.out" 2>"$WORK_DIR/budget.err" ||
  fail "an exhausted budget must not fail the lookup"
elapsed=$((SECONDS - started))
[ "$elapsed" -le 6 ] || fail "the lookup must stop at its time budget, took ${elapsed}s"
grep -Fq "Server country lookup ran out of time; 24 servers left without a country" "$WORK_DIR/budget.err" ||
  fail "an exhausted budget must say how many servers were left: $(cat "$WORK_DIR/budget.err")"
[ "$(cut -d' ' -f1 "$WORK_DIR/dig.log" | sort -u | wc -l)" -le 16 ] ||
  fail "no batch may start after the budget ran out"

printf 'country lookup budget checks passed\n'
