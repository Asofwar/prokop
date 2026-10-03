#!/usr/bin/env bash
# Whether the TPROXY marking rule (`ip rule add fwmark M/M table prokop
# priority 105`, nft/apply.uc ensure_tproxy_route_rule) is present is read
# from `ip rule list`, one rule per line (UC-163). The lookup and the fwmark
# of two different rules do not make one; the rule counts by its numeric
# table id (105) as well as by the rt_tables name, which `ip` only prints
# while /etc/iproute2/rt_tables holds it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROKOP_LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR:?}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
  "-4 rule list") printf '%b\n' "$RULES" ;;
  "-6 rule list") printf '%b\n' "$RULES" ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 "$WORK_DIR/bin/ip"
export PATH="$WORK_DIR/bin:$PATH"

present() {
  RULES="$1" ucode -L "$PROKOP_LIB" "$PROKOP_LIB/nft/apply.uc" tproxy-marking-rule-present prokop 0x04000000
}
expect_present() {
  present "$2" || fail "$1: the marking rule was not found in: $2"
  printf 'ok - %s\n' "$1"
}
expect_absent() {
  if present "$2"; then
    fail "$1: a marking rule was found in: $2"
  fi
  printf 'ok - %s\n' "$1"
}

BASE='0:\tfrom all lookup local\n32766:\tfrom all lookup main\n32767:\tfrom all lookup default'
expect_present "the rule by its rt_tables name" \
  "0:\tfrom all lookup local\n105:\tfrom all fwmark 0x4000000/0x4000000 lookup prokop\n32766:\tfrom all lookup main"
expect_present "the rule by its numeric table id (no rt_tables entry)" \
  "$BASE\n105:\tfrom all fwmark 0x4000000/0x4000000 lookup 105"
expect_absent "the lookup and the fwmark of two different rules" \
  "$BASE\n100:\tfrom all fwmark 0x4000000/0x4000000 lookup main\n105:\tfrom all lookup prokop"
expect_absent "another table" \
  "$BASE\n105:\tfrom all fwmark 0x4000000/0x4000000 lookup 106"
expect_absent "another mask" \
  "$BASE\n105:\tfrom all fwmark 0x4000000/0xff000000 lookup prokop"
expect_absent "another priority" \
  "$BASE\n200:\tfrom all fwmark 0x4000000/0x4000000 lookup prokop"
expect_absent "a narrower rule (source limited)" \
  "$BASE\n105:\tfrom 192.168.1.0/24 fwmark 0x4000000/0x4000000 lookup prokop"
expect_absent "no rule" "$BASE"

printf 'tproxy rule detection checks passed\n'
