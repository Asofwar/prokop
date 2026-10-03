#!/usr/bin/env bash
set -eo pipefail

# config_contract_matrix.sh must work from a plain file copy (tarball, git
# worktree read through another OS, offline runner) and must never reach the
# network or write refs into the developer repository. Run it from a copy
# without .git and with a git double that records every call.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STABLE_VERSION="0.7.19.9"
STABLE_COMMIT="68d516e85b9a81b5a37e8e258610098ed03b02d1"
FIXTURE="tests/fixtures/config_contract/stable-$STABLE_VERSION.json"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

COPY="$WORK_DIR/copy"
mkdir -p "$COPY/tests/helpers" "$COPY/tests/fixtures"
cp -R "$ROOT_DIR/prokop" "$ROOT_DIR/luci-app-prokop" "$COPY/"
cp "$ROOT_DIR/install.sh" "$COPY/"
cp "$ROOT_DIR/tests/config_contract_matrix.sh" "$COPY/tests/"
cp "$ROOT_DIR/tests/helpers/config_contract_matrix.js" "$COPY/tests/helpers/"
if [ -d "$ROOT_DIR/tests/fixtures/config_contract" ]; then
  cp -R "$ROOT_DIR/tests/fixtures/config_contract" "$COPY/tests/fixtures/"
fi

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GIT_CALL_LOG:?}"
exit 1
SH
chmod 0755 "$WORK_DIR/bin/git"
: >"$WORK_DIR/git.log"

if ! env -u PROKOP_STABLE_REPO -u PROKOP_STABLE_REF -u PROKOP_STABLE_COMMIT -u PROKOP_STABLE_VERSION \
  -u PROKOP_STABLE_INVENTORY \
  PATH="$WORK_DIR/bin:$PATH" GIT_CALL_LOG="$WORK_DIR/git.log" \
  bash "$COPY/tests/config_contract_matrix.sh" >"$WORK_DIR/run.out" 2>&1; then
  cat "$WORK_DIR/run.out" >&2
  fail "the contract matrix must pass from a plain copy without git history"
fi

if grep -Eq '(^| )(fetch|pull|clone|push|tag|update-ref|remote)( |$)' "$WORK_DIR/git.log"; then
  cat "$WORK_DIR/git.log" >&2
  fail "the contract matrix must never fetch or write git refs"
fi

# The committed inventory must stay what the stable release really contains.
# Only reading objects that are already local is allowed here.
if git -C "$ROOT_DIR" cat-file -e "$STABLE_COMMIT^{commit}" 2>/dev/null; then
  mkdir -p "$WORK_DIR/stable-$STABLE_VERSION"
  git -C "$ROOT_DIR" archive "$STABLE_COMMIT" | tar -x -C "$WORK_DIR/stable-$STABLE_VERSION" ||
    fail "failed to read the local stable commit $STABLE_COMMIT"
  node "$ROOT_DIR/tests/helpers/config_contract_matrix.js" --inventory "$WORK_DIR/stable-$STABLE_VERSION" \
    --version "$STABLE_VERSION" --commit "$STABLE_COMMIT" >"$WORK_DIR/regenerated.json"
  node - "$ROOT_DIR/$FIXTURE" "$WORK_DIR/regenerated.json" <<'NODE'
const fs = require("fs");
const committed = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const regenerated = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
if (JSON.stringify(committed) !== JSON.stringify(regenerated)) {
  console.error("FAIL: committed stable inventory differs from the stable commit; regenerate it with --inventory");
  process.exit(1);
}
NODE
else
  printf 'note: stable commit %s is not in the local object store; fixture provenance not rechecked\n' "$STABLE_COMMIT"
fi

printf 'config contract matrix hermetic checks passed\n'
