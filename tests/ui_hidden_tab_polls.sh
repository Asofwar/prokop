#!/usr/bin/env bash
set -euo pipefail
# FE-7: a forgotten background tab must not keep the router busy. Every
# periodic poll of a page (setInterval in fe-app-prokop/src/prokop/tabs)
# skips its turn while the tab is hidden (helpers/isPageHidden.ts) within
# the first lines of its callback.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status=0
while IFS=: read -r file line _; do
  if ! sed -n "${line},$((line + 3))p" "$file" | grep -q 'isPageHidden()'; then
    printf 'FAIL: %s:%s polls while the tab is hidden\n' "${file#"$ROOT_DIR/"}" "$line" >&2
    status=1
  fi
done < <(grep -rn 'setInterval(' "$ROOT_DIR/fe-app-prokop/src/prokop/tabs" --include='*.ts' | grep -v '/tests/' | grep -v 'ReturnType<typeof setInterval>')
[ "$status" = 0 ] || exit 1
echo "ui_hidden_tab_polls: OK"
