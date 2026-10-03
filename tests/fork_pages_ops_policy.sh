#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$ROOT_DIR/ops/mirror/router-bootstrap.sh"
PYTHON_BIN="${PYTHON_BIN:-python3}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# Release tooling and repository metadata belong to the fork. The legacy
# upstream mirror hosts may only be named where they are recognised for
# cleanup or by the third-party script the Zapret-Manager cache rewrites.
if grep -RIl -e 'slayer326' -e 'fold8.ru' "$ROOT_DIR/ops" "$ROOT_DIR/.github" >"$WORK_DIR/upstream"; then
  cat "$WORK_DIR/upstream" >&2
  fail "release tooling or metadata still points at the upstream project"
fi
grep -RIl -e 'mirror.infotechtg.ru' -e 'mirror.51343.ru' "$ROOT_DIR/ops" "$ROOT_DIR/.github" |
  sed "s#^$ROOT_DIR/##" | sort >"$WORK_DIR/legacy" || true
while read -r path; do
  case "$path" in
    ops/mirror/README.md|ops/mirror/zapret-manager-cache.py) ;;
    *) fail "$path names a legacy upstream mirror host" ;;
  esac
done <"$WORK_DIR/legacy"
[[ "$(cat "$ROOT_DIR/.github/CODEOWNERS")" == '*       @Asofwar' ]] ||
  fail "CODEOWNERS does not name the fork owner"

# The Zapret-Manager cache serves the operator's own public URL, never an
# assumed one, and refuses to start before it is configured.
grep -Fq 'ZAPRET_MANAGER_MIRROR: ${ZAPRET_MANAGER_MIRROR:?' "$ROOT_DIR/ops/mirror/home/zapret-compose.yml" ||
  fail "the cache compose file does not require an explicit mirror URL"
if env -u ZAPRET_MANAGER_MIRROR PYTHONDONTWRITEBYTECODE=1 \
    timeout 10 "$PYTHON_BIN" "$ROOT_DIR/ops/mirror/zapret-manager-cache.py" \
    >"$WORK_DIR/cache.log" 2>&1; then
  fail "the Zapret-Manager cache started without ZAPRET_MANAGER_MIRROR"
fi
grep -Fq 'Set ZAPRET_MANAGER_MIRROR' "$WORK_DIR/cache.log" ||
  fail "the Zapret-Manager cache did not explain its missing mirror URL"

# router-bootstrap.sh trusts nothing from the mirror itself: no apk key, no
# prokop feed. It only hands an explicit mirror to the fork's installer.
for forbidden in '/etc/apk/keys' 'repositories.d' 'forkop-apk.pem' 'MIRROR_LATEST' 'uci '; do
  if grep -Fq -- "$forbidden" "$BOOTSTRAP"; then
    fail "router-bootstrap.sh still uses $forbidden"
  fi
done

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/installer" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$FAKE_ARGS"
SH
# wget -q -O FILE URL: log the URL, fail for FAKE_FAIL_URL, else "download"
# the fake installer.
cat >"$WORK_DIR/bin/wget" <<'SH'
#!/bin/sh
out="" url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -O) out="$2"; shift ;;
    -q) ;;
    *) url="$1" ;;
  esac
  shift
done
printf '%s\n' "$url" >>"$FAKE_LOG"
[ "$url" != "${FAKE_FAIL_URL:-}" ] || exit 1
cp "$FAKE_INSTALLER" "$out"
SH
chmod +x "$WORK_DIR/bin/wget"

bootstrap() {
  : >"$WORK_DIR/wget.log"
  rm -f "$WORK_DIR/args"
  env -u PROKOP_MIRROR_BASE -u PROKOP_RELEASE_BASE_URL -u PROKOP_RELEASE_REPO \
    PATH="$WORK_DIR/bin:$PATH" FAKE_LOG="$WORK_DIR/wget.log" FAKE_ARGS="$WORK_DIR/args" \
    FAKE_INSTALLER="$WORK_DIR/installer" FAKE_FAIL_URL="${FAIL_URL:-}" \
    sh "$BOOTSTRAP" "$@"
}

if bootstrap >"$WORK_DIR/out" 2>&1; then
  fail "router-bootstrap.sh ran without a mirror URL"
fi
grep -Fq 'no default mirror' "$WORK_DIR/out" || fail "router-bootstrap.sh did not explain the missing mirror"
[[ ! -s "$WORK_DIR/wget.log" ]] || fail "router-bootstrap.sh downloaded something without a mirror"

if bootstrap ftp://mirror.example >/dev/null 2>&1; then
  fail "router-bootstrap.sh accepted a non-HTTP mirror URL"
fi

bootstrap https://mirror.example// --sing-box tiny >/dev/null 2>&1 ||
  fail "router-bootstrap.sh failed with an explicit mirror"
[[ "$(cat "$WORK_DIR/wget.log")" == 'https://asofwar.github.io/prokop/install.sh' ]] ||
  fail "router-bootstrap.sh did not take the installer from the fork channel"
[[ "$(cat "$WORK_DIR/args")" == $'--mirror\nhttps://mirror.example\n--sing-box\ntiny' ]] ||
  fail "router-bootstrap.sh passed unexpected installer arguments: $(cat "$WORK_DIR/args")"

FAIL_URL='https://asofwar.github.io/prokop/install.sh' \
  bootstrap https://mirror.example >/dev/null 2>&1 ||
  fail "router-bootstrap.sh did not fall back to GitHub Releases"
[[ "$(tail -n 1 "$WORK_DIR/wget.log")" == 'https://github.com/Asofwar/prokop/releases/latest/download/install.sh' ]] ||
  fail "router-bootstrap.sh fell back to an unexpected installer URL"
[[ "$(head -n 2 "$WORK_DIR/args")" == $'--mirror\nhttps://mirror.example' ]] ||
  fail "router-bootstrap.sh did not pass the mirror after the fallback"

printf 'fork ops policy checks passed\n'
