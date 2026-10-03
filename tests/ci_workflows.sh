#!/usr/bin/env bash
set -euo pipefail

# The CI contract: every job is bounded in time, only actions the repository
# policy allows are used, superseded runs are cancelled only for pull requests
# and feature branches, the backend shards cover every test exactly once, and
# the tests that read LuCI and frontend sources run when those change.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOWS="$ROOT_DIR/.github/workflows"
BACKEND="$WORKFLOWS/backend-ci.yml"
SHARDS="$ROOT_DIR/.github/scripts/backend_test_shards.py"
SDK_CACHE="$ROOT_DIR/.github/scripts/openwrt-sdk-cache.sh"
PYTHON_BIN="${PYTHON_BIN:-python3}"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

for file in "$BACKEND" "$SHARDS" "$SDK_CACHE" "$ROOT_DIR/.github/dependabot.yml" \
  "$ROOT_DIR/.github/actions/setup-ucode/action.yml"; do
  [[ -s "$file" ]] || fail "missing $file"
done

# The shards of the matrix in backend-ci.yml cover every tests/*.sh once.
matrix_line="$(grep -E '^        shard: \[[0-9, ]+\]$' "$BACKEND")" ||
  fail "backend-ci.yml has no shard matrix"
shard_total="$(tr -cd ',' <<<"$matrix_line" | wc -c)"
shard_total=$((shard_total + 1))
"$PYTHON_BIN" "$SHARDS" check --total "$shard_total" >/dev/null ||
  fail "the $shard_total backend shards do not cover every test exactly once"
plans=""
for ((index = 0; index < shard_total; index++)); do
  plans+="$("$PYTHON_BIN" "$SHARDS" plan --total "$shard_total" --index "$index" 2>/dev/null)"$'\n'
done
expected="$(cd "$ROOT_DIR" && printf '%s\n' tests/*.sh | LC_ALL=C sort)"
[[ "$(grep -v '^$' <<<"$plans" | LC_ALL=C sort)" == "$expected" ]] ||
  fail "the union of the shard plans is not tests/*.sh"

# The SDK cache key follows the URLs build.sh downloads.
sdk_out="$(env -u GITHUB_OUTPUT bash "$SDK_CACHE" outputs /sdk-cache-test)"
grep -Fxq 'enabled=true' <<<"$sdk_out" || fail "openwrt-sdk-cache.sh cannot read the SDK URLs: $sdk_out"
for kind in IPK APK; do
  url="$(sed -n "s/^${kind}_SDK_URL=\"\${${kind}_SDK_URL:-\(.*\)}\"\$/\1/p" "$ROOT_DIR/build.sh")"
  [[ -n "$url" ]] || fail "build.sh has no default ${kind}_SDK_URL"
  grep -Fxq "/sdk-cache-test/$(basename "$url")" <<<"$sdk_out" ||
    fail "the SDK cache does not hold $url"
done
other_key="$(env -u GITHUB_OUTPUT IPK_SDK_URL=https://example.invalid/other.tar.zst \
  bash "$SDK_CACHE" outputs /sdk-cache-test | grep '^key=')"
[[ "$other_key" != "$(grep '^key=' <<<"$sdk_out")" ]] ||
  fail "the SDK cache key ignores the SDK URL"

if ! "$PYTHON_BIN" -c 'import yaml' 2>/dev/null; then
  printf 'PyYAML is unavailable; structural workflow checks skipped\n'
  printf 'ci workflow checks passed\n'
  exit 0
fi

"$PYTHON_BIN" - "$ROOT_DIR" <<'PY' || fail "workflow contract violated"
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
problems = []


def load(path):
    import yaml

    return yaml.safe_load(path.read_text(encoding="utf-8"))


def triggers(doc):
    # PyYAML reads the bare key "on" as the boolean True.
    return doc.get("on", doc.get(True)) or {}


ALLOWED = re.compile(
    r"^(\./.+|actions/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?@v[0-9]+(\.[0-9]+){0,2}"
    r"|softprops/action-gh-release@.+)$"
)


def check_uses(where, uses):
    if not ALLOWED.match(uses):
        problems.append(f"{where}: {uses} is not allowed by the repository Actions policy")


workflows = {path.name: load(path) for path in sorted((root / ".github/workflows").glob("*.yml"))}
for name, doc in workflows.items():
    for job_id, job in doc["jobs"].items():
        where = f"{name}:{job_id}"
        if "uses" in job:
            check_uses(where, job["uses"])
            continue
        timeout = job.get("timeout-minutes")
        if not isinstance(timeout, int) or not 1 <= timeout <= 60:
            problems.append(f"{where}: needs timeout-minutes between 1 and 60, has {timeout!r}")
        for step in job.get("steps", []):
            if "uses" in step:
                check_uses(f"{where}:{step.get('name', step['uses'])}", step["uses"])
        if "apt-get" in str(job.get("steps")) and name == "shellcheck.yml":
            if "command -v shellcheck" not in str(job.get("steps")):
                problems.append(f"{where}: installs ShellCheck although the image ships it")

for action in sorted((root / ".github/actions").glob("*/action.yml")):
    for step in load(action)["runs"].get("steps", []):
        if "uses" in step:
            check_uses(f"{action.parent.name}:{step.get('name')}", step["uses"])

# Cancelling only superseded pull-request and feature-branch runs: every
# other event falls back to a group of its own (github.run_id).
CANCELLABLE = (
    "(github.event_name == 'pull_request' || (github.event_name == 'push' && "
    "github.ref_type == 'branch' && github.ref != 'refs/heads/main')) && "
    "(github.event.pull_request.number || github.ref) || github.run_id }}"
)
prefixes = {}
for name, doc in workflows.items():
    concurrency = doc.get("concurrency")
    if name == "pages.yml":
        if concurrency != {"group": "pages", "cancel-in-progress": False}:
            problems.append("pages.yml: deploys must queue, never cancel")
        continue
    if not concurrency:
        problems.append(f"{name}: no concurrency group")
        continue
    group = concurrency["group"]
    if concurrency["cancel-in-progress"] is True:
        if not group.endswith(CANCELLABLE):
            problems.append(f"{name}: cancels runs outside pull requests and feature branches")
        prefixes[name] = group[: -len(CANCELLABLE)]
    elif concurrency["cancel-in-progress"] is not False:
        problems.append(f"{name}: cancel-in-progress must be a literal")
called = {"backend-ci.yml", "frontend-ci.yml"}
for name in called:
    if not prefixes.get(name, "").startswith(name.removesuffix(".yml") + "-"):
        problems.append(f"{name}: its group must not collide with the calling workflow's")

backend = workflows["backend-ci.yml"]
on = triggers(backend)
for event in ("workflow_call", "workflow_dispatch", "pull_request", "push"):
    if event not in on:
        problems.append(f"backend-ci.yml: lost the {event} trigger")
if on["push"]["branches"] != ["main"]:
    problems.append("backend-ci.yml: push must stay limited to main")
if on["pull_request"]["paths"] != on["push"]["paths"]:
    problems.append("backend-ci.yml: pull_request and push path filters differ")
for path in ("prokop/files/**", "build.sh", "install.sh", "tests/**", "luci-app-prokop/**",
             "fe-app-prokop/**", ".github/**"):
    if path not in on["pull_request"]["paths"]:
        problems.append(f"backend-ci.yml: path filter misses {path}")
jobs = backend["jobs"]
aggregate = jobs.get("backend-checks", {})
if aggregate.get("name") != "Backend Runtime Checks" or aggregate.get("if") != "always()":
    problems.append("backend-ci.yml: the aggregate check must be 'Backend Runtime Checks', if: always()")
if sorted(aggregate.get("needs", [])) != ["tests", "ucode"]:
    problems.append("backend-ci.yml: the aggregate check must need the syntax check and all shards")
shards = jobs["tests"]
if shards["strategy"].get("fail-fast") is not False:
    problems.append("backend-ci.yml: one failing shard must not cancel the others")
node = [s for s in shards["steps"] if str(s.get("uses", "")).startswith("actions/setup-node@")]
if not node or int(str(node[0]["with"]["node-version"]).split(".")[0]) < 21:
    problems.append("backend-ci.yml: shards need Node >= 21 (navigator global)")
if "Check ucode syntax" not in [s.get("name") for s in jobs["ucode"]["steps"]]:
    problems.append("backend-ci.yml: lost the ucode syntax check")
if any(s.get("name") == "Check ucode syntax" for s in shards["steps"]):
    problems.append("backend-ci.yml: the syntax check belongs to one job, not every shard")

build = workflows["build.yml"]
release = build["jobs"]["release"]
if release["if"] != "startsWith(github.ref, 'refs/tags/') || inputs.publish_release":
    problems.append("build.yml: release must stay limited to tags and publish_release")
if sorted(release["needs"]) != ["backend-checks", "build", "frontend-checks", "preparation"]:
    problems.append("build.yml: release must wait for the build and both check workflows")
for step in build["jobs"]["build"]["steps"]:
    if str(step.get("uses", "")).startswith("actions/cache"):
        path = str(step["with"]["path"])
        if "filtered-bin" in path or ".build" in path or "steps.sdk.outputs.paths" not in path:
            problems.append(f"build.yml: caches more than the SDK downloads: {path}")

dependabot = load(root / ".github/dependabot.yml")
ecosystems = [update["package-ecosystem"] for update in dependabot["updates"]]
if ecosystems != ["github-actions"]:
    problems.append(f"dependabot.yml: only github-actions updates, got {ecosystems}")
if dependabot["updates"][0]["schedule"]["interval"] != "weekly":
    problems.append("dependabot.yml: updates must be weekly")

for problem in problems:
    print(problem, file=sys.stderr)
sys.exit(1 if problems else 0)
PY

printf 'ci workflow checks passed\n'
