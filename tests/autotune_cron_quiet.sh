#!/usr/bin/env bash
set -euo pipefail

# autotune/manager.uc reports by printing a JSON result, and the service calls
# it on every cron refresh: a start, a reload and a stop all pass through
# refresh_cron or remove_cron_jobs. Those calls must not let that JSON reach the
# output of an init.d action.
#
# Before the fix, `/etc/init.d/prokop restart` printed
#     { "status": "ok", "enabled": false, "changed": false }
# because module_success runs the module through system(), which leaves stdout
# attached to the caller's terminal. The line is autotune reporting that its
# cron line is absent while the mode is off - that is, nothing being wrong - but
# an operator reads "enabled": false as a verdict on the service they just
# restarted, and the real result of the restart scrolls past above it.
#
# The outcome of the autotune call is deliberately ignored (autotune never
# blocks the service), so only the capture keeps it quiet.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIFECYCLE_UC="$ROOT_DIR/prokop/files/usr/lib/service/lifecycle.uc"

# shellcheck source=tests/helpers/source_checks.sh
. "$ROOT_DIR/tests/helpers/source_checks.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# The manager runs through the one helper, and that helper captures.
helper="$(source_function "$LIFECYCLE_UC" sync_autotune_cron)" || exit 1
printf '%s' "$helper" | grep -Fq 'module_capture(AUTOTUNE_MANAGER_UC' ||
  fail 'sync_autotune_cron must reach autotune through module_capture'
source_refute_text 'sync_autotune_cron must not run autotune through system()' \
  -E 'module_(success|status)\(' "$helper"

# Both cron paths go through it, and neither reaches the manager any other way.
for region_name in refresh_cron remove_cron_jobs; do
  region="$(source_function "$LIFECYCLE_UC" "$region_name")" || exit 1
  printf '%s' "$region" | grep -Fq 'sync_autotune_cron(' ||
    fail "$region_name must sync the autotune cron line through sync_autotune_cron"
  source_refute_text \
    "$region_name must not name AUTOTUNE_MANAGER_UC itself; it would bypass the capture" \
    -F 'AUTOTUNE_MANAGER_UC' "$region"
done

# Nothing else in the service may run the manager with its output attached.
lifecycle_body="$(cat "$LIFECYCLE_UC")"
[ -n "$lifecycle_body" ] || fail 'lifecycle.uc is empty'
source_refute_text \
  'only sync_autotune_cron may invoke AUTOTUNE_MANAGER_UC, and only by capture' \
  -E 'module_(success|status)\(AUTOTUNE_MANAGER_UC' "$lifecycle_body"

printf 'autotune cron quiet checks passed\n'
