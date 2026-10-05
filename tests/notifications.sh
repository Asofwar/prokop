#!/usr/bin/env bash
set -euo pipefail
# Notifications (notify/): events from the history and subscription updates
# are queued without waiting, sent to Telegram and a webhook with the token
# and URL kept off every command line, deduplicated, rate-limited, retried
# only when the failure may pass, sent directly when the proxy route fails,
# and the connection, sing-box and subscription checks report transitions.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/prokop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TOKEN="123456789:AAH-secretsecretsecretsecretsecret_x"
WEBHOOK="https://ntfy.example/prokop-secret-topic"
mkdir -p "$WORK/bin" "$WORK/run"

# curl: records its arguments and config file, answers with the HTTP code in
# $WORK/code.<channel> (or fails with the exit status in $WORK/exit.<channel>);
# a request through the proxy uses $WORK/proxy-exit when it exists.
cat >"$WORK/bin/curl" <<SH
#!/bin/sh
echo "\$*" >>"$WORK/argv.log"
out=""; cfg=""; proxy=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift ;;
    -K) cfg="\$2"; shift ;;
    -x) proxy="\$2"; shift ;;
  esac
  shift
done
channel=webhook
grep -q 'api.telegram' "\$cfg" && channel=telegram
{ echo "ARGS \$*"; echo "PROXY \$proxy"; echo "CHANNEL \$channel"; cat "\$cfg"; } >>"$WORK/curl.log"
for f in \$(sed -n 's/^data-urlencode = "text@\(.*\)"$/\1/p; s/^data-binary = "@\(.*\)"$/\1/p' "\$cfg"); do
  { echo "BODY-BEGIN"; cat "\$f"; echo; echo "BODY-END"; } >>"$WORK/curl.log"
done
if [ -n "\$proxy" ] && [ -e "$WORK/proxy-exit" ]; then exit "\$(cat "$WORK/proxy-exit")"; fi
if [ -e "$WORK/exit.\$channel" ]; then exit "\$(cat "$WORK/exit.\$channel")"; fi
[ -e "$WORK/body.\$channel" ] && cp "$WORK/body.\$channel" "\$out"
printf '%s' "\$(cat "$WORK/code.\$channel" 2>/dev/null || echo 200)"
SH
cat >"$WORK/bin/logger" <<SH
#!/bin/sh
echo "logger \$*" >>"$WORK/logger.log"
SH
# The Prokop CLI as the checks call it.
cat >"$WORK/bin/prokop" <<SH
#!/bin/sh
case "\$1 \$2" in
  "clash_api get_proxies")
    [ -e "$WORK/clash-down" ] && { echo '{"success":false,"error":"clash_api_unreachable"}'; exit 1; }
    echo '{"proxies":{"vpn-out":{"type":"Selector"},"backup-out":{"type":"URLTest"}}}' ;;
  "clash_api get_proxy_latency")
    if [ -e "$WORK/down.\$3" ]; then echo '{"success":false,"error":"latency_failed"}'; exit 1; fi
    echo '{"delay":120}' ;;
  get_subscription_metadata*)
    cat "$WORK/meta.\$2" 2>/dev/null || echo '{}' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$WORK/bin/"*

export PATH="$WORK/bin:$PATH" PROKOP_LIB="$LIB" PROKOP_BIN="$WORK/bin/prokop" \
  PROKOP_RUNTIME_STATE_DIR="$WORK/run" PROKOP_UCI_STATE_FILE="$WORK/uci" \
  PROKOP_RELOAD_LOCK_DIR="$WORK/reload.lock" PROKOP_STOP_REQUESTED_FILE="$WORK/run/stop.requested" \
  PROKOP_NOTIFY_HEALTH_FILE="$WORK/health.json" PROKOP_NOTIFY_HOSTNAME_FILE="$WORK/hostname" \
  PROKOP_CRONTAB_FILE="$WORK/crontab" PROKOP_NOTIFY_CRONTAB="$WORK/bin/crontab" TMP_DIR="$WORK" \
  PROKOP_HISTORY_FILE="$WORK/history.jsonl" PROKOP_NOTIFY_NO_FLUSH=1
printf 'Flint2\n' >"$WORK/hostname"
printf '{"overall":"ok","guard":{"active":false}}\n' >"$WORK/health.json"
cat >"$WORK/bin/crontab" <<SH
#!/bin/sh
cp "\$1" "$WORK/crontab"
SH
chmod +x "$WORK/bin/crontab"

manager() { ucode -L "$LIB" "$LIB/notify/manager.uc" "$@"; }
record() { ucode -L "$LIB" "$LIB/diagnostics/health.uc" record "$@"; }
queued() { find "$WORK/run/notify/queue" -name '*.json' 2>/dev/null | wc -l; }
sent_count() { cat "$WORK/curl.log" 2>/dev/null | grep -c '^CHANNEL' || true; }
reset() {
  rm -rf "$WORK/run" "$WORK"/curl.log "$WORK"/argv.log "$WORK"/logger.log "$WORK"/code.* "$WORK"/exit.* \
    "$WORK"/body.* "$WORK/proxy-exit" "$WORK"/down.* "$WORK/clash-down" "$WORK"/meta.* "$WORK/history.jsonl"
  mkdir -p "$WORK/run"
  printf '0\n' >"$WORK/run/shutdown_correctly"
  cat >"$WORK/uci" <<UCI
prokop.settings=settings
prokop.settings.notify_enabled=1
prokop.settings.notify_telegram_token=$TOKEN
prokop.settings.notify_telegram_chat_id=-1001234567
prokop.settings.notify_webhook_url=$WEBHOOK
prokop.vpn=section
prokop.vpn.action=connection
prokop.vpn.label=Main VPN
prokop.vpn.subscription_urls=https://sub.example/s/abc
prokop.backup=section
prokop.backup.action=connection
prokop.off=section
prokop.off.action=connection
prokop.off.enabled=0
UCI
}
setting() { printf 'prokop.settings.%s=%s\n' "$1" "$2" >>"$WORK/uci"; }

# --- off: nothing is queued ------------------------------------------------
reset
sed -i '/notify_enabled/d' "$WORK/uci"
record reload failure
[ "$(queued)" -eq 0 ] || fail "an event was queued while notifications are off"
[ -s "$WORK/history.jsonl" ] || fail "the history record itself failed"

# --- a failed reload reaches both channels, secrets stay off argv ------------
reset
record reload failure
record reload success
record snapshot_create success
[ "$(queued)" -eq 1 ] || fail "only the failed reload is a notification, queued $(queued)"
manager flush
[ "$(queued)" -eq 0 ] || fail "the queue was not drained"
[ "$(sent_count)" -eq 2 ] || fail "expected one message per channel: $(cat "$WORK/curl.log")"
grep -q "bot$TOKEN/sendMessage" "$WORK/curl.log" || fail "the Telegram URL is not in the curl config"
grep -q 'chat_id=-1001234567' "$WORK/curl.log" || fail "chat id missing"
grep -q 'Перезагрузка Prokop завершилась ошибкой' "$WORK/curl.log" || fail "the reload text is missing"
grep -q 'Состояние сейчас: Норма' "$WORK/curl.log" || fail "the health line is missing"
grep -q 'Prokop · Flint2' "$WORK/curl.log" || fail "the title is missing"
if grep -q -e "$TOKEN" -e 'prokop-secret-topic' "$WORK/argv.log"; then fail "a secret reached a command line"; fi
grep -q -- '--noproxy' "$WORK/argv.log" || fail "the direct route must ignore proxy variables"
grep -q '"priority": 5' "$WORK/curl.log" || fail "the webhook JSON body is missing"
[ -z "$(find "$WORK/run/notify" -name 'req.*')" ] || fail "request files were left behind"
[ "$(stat -c %a "$WORK/run/notify")" = 700 ] || fail "the notify directory is not private"
[ "$(stat -c %a "$WORK/run/notify/state.json")" = 600 ] || fail "the state file is not private"

# --- the same failure again within its window is not sent again -------------
: >"$WORK/curl.log"
record reload failure
manager flush
[ "$(sent_count)" -eq 0 ] || fail "a repeated reload failure was sent again"

# --- restore and autotune texts; a user's own success is silent -------------
for case in "restore recovered|вернул прежнюю конфигурацию" "restore failure|Нужна проверка" \
  "autotune_rollback success automatic fake_cand|Автотюн откатил стратегию DPI: новая стратегия (fake_cand)" \
  "start failure|Prokop не запустился"; do
  reset
  args="${case%%|*}"; text="${case#*|}"
  # shellcheck disable=SC2086
  record $args
  manager flush
  grep -qF "$text" "$WORK/curl.log" || fail "no text '$text' for $args"
done
for args in "restore success" "autotune_rollback success manual" "restore not_started" "cron_refresh failure"; do
  reset
  # shellcheck disable=SC2086
  record $args
  [ "$(queued)" -eq 0 ] || fail "'$args' must not be notified"
done

# --- a guard left behind is said in the message ----------------------------
reset
printf '{"overall":"error","guard":{"active":true}}\n' >"$WORK/health.json"
record reload failure
manager flush
grep -q 'защитная блокировка' "$WORK/curl.log" || fail "the active guard is not reported"
printf '{"overall":"ok","guard":{"active":false}}\n' >"$WORK/health.json"

# --- a category that is off is not queued ----------------------------------
reset
setting notify_on_rollback 0
record reload failure
[ "$(queued)" -eq 0 ] || fail "the rollback category is off"

# --- invalid channel values are no channel ---------------------------------
reset
sed -i 's/^prokop.settings.notify_telegram_token=.*/prokop.settings.notify_telegram_token=bad token/; /notify_webhook_url/d' "$WORK/uci"
out="$(manager test || true)"
[ "$(printf '%s' "$out" | jq -r .reason)" = not_configured ] || fail "an invalid token counts as a channel: $out"

# --- test: per-channel result, refusals named -------------------------------
reset
printf '401' >"$WORK/code.telegram"
printf '{"ok":false}' >"$WORK/body.telegram"
out="$(manager test || true)"
[ "$(printf '%s' "$out" | jq -r .status)/$(printf '%s' "$out" | jq -r .reason)" = failed/delivery_failed ] ||
  fail "a refused token is a failed test: $out"
manager test >/dev/null && fail "a failed test must exit non-zero"
[ "$(printf '%s' "$out" | jq -r '.channels[] | select(.channel=="telegram") | .reason')" = token_rejected ] ||
  fail "a 401 is a rejected token: $out"
[ "$(printf '%s' "$out" | jq -r '.channels[] | select(.channel=="webhook") | .status')" = ok ] ||
  fail "the webhook still went out: $out"
printf '400' >"$WORK/code.telegram"
printf '{"ok":false,"description":"Bad Request: chat not found"}' >"$WORK/body.telegram"
out="$(manager test || true)"
[ "$(printf '%s' "$out" | jq -r '.channels[] | select(.channel=="telegram") | .reason')" = chat_not_found ] ||
  fail "an unknown chat is named: $out"
if printf '%s' "$out" | grep -q -e "$TOKEN" -e secret-topic; then fail "the test answer holds a secret"; fi
status="$(manager status)"
if printf '%s' "$status" | grep -q -e "$TOKEN" -e secret-topic -e 1001234567; then fail "status holds a secret: $status"; fi
[ "$(printf '%s' "$status" | jq -r .last.telegram.reason)" = chat_not_found ] || fail "status keeps the last result: $status"

# --- a failure that may pass is retried by the next tick, a refusal is not ---
reset
printf '7' >"$WORK/exit.telegram"
printf '403' >"$WORK/code.webhook"
record start failure
manager flush
[ "$(jq '.outbox | length' "$WORK/run/notify/state.json")" -eq 1 ] || fail "only the network failure stays queued"
rm -f "$WORK/exit.telegram"
: >"$WORK/curl.log"
manager tick
grep -q 'CHANNEL telegram' "$WORK/curl.log" || fail "the tick did not retry the message"
grep -q 'CHANNEL webhook' "$WORK/curl.log" && fail "a refused webhook was retried"
[ "$(jq '.outbox | length' "$WORK/run/notify/state.json")" -eq 0 ] || fail "the delivered message is still queued"

# --- the proxy route falls back to the direct one ---------------------------
reset
setting notify_via_proxy 1
setting notify_via_proxy_section vpn
printf '7' >"$WORK/proxy-exit"
record start failure
manager flush
grep -q '^PROXY http://127.0.0.1:4533' "$WORK/curl.log" || fail "the proxy route was not tried"
[ "$(grep -c '^PROXY $' "$WORK/curl.log")" -eq 2 ] || fail "both channels were not sent directly after the proxy"
[ "$(manager status | jq -r .last.telegram.route)" = direct ] || fail "status does not name the route"

# --- rate limit: held back, then counted -----------------------------------
reset
export PROKOP_NOTIFY_RATE_MAX=1
record start failure
manager flush
record reload failure
manager flush
[ "$(grep -c 'CHANNEL telegram' "$WORK/curl.log")" -eq 1 ] || fail "the rate limit let a second message out"
[ "$(jq .dropped "$WORK/run/notify/state.json")" -eq 1 ] || fail "the held-back event is not counted"
unset PROKOP_NOTIFY_RATE_MAX
jq '.sent_times = []' "$WORK/run/notify/state.json" >"$WORK/s" && mv "$WORK/s" "$WORK/run/notify/state.json"
record restore failure
manager flush
grep -q 'Пропущено уведомлений из-за ограничения частоты: 1' "$WORK/curl.log" || fail "the next message does not count the held-back ones"

# --- connections: down after two failed checks, up once ---------------------
export PROKOP_NOTIFY_NODE_CHECK_SECONDS=0 PROKOP_NOTIFY_SUBSCRIPTION_CHECK_SECONDS=100000
reset
manager tick
[ "$(sent_count)" -eq 0 ] || fail "a working connection was reported"
: >"$WORK/down.vpn-out"
manager tick
[ "$(sent_count)" -eq 0 ] || fail "one failed check is no outage"
manager tick
grep -q 'Подключение «Main VPN» не отвечает' "$WORK/curl.log" || fail "the outage was not reported"
: >"$WORK/curl.log"
manager tick
[ "$(sent_count)" -eq 0 ] || fail "the outage was reported twice"
rm -f "$WORK/down.vpn-out"
manager tick
grep -q 'Подключение «Main VPN» снова работает' "$WORK/curl.log" || fail "the recovery was not reported"
grep -q 'backup' "$WORK/curl.log" && fail "a working URLTest connection was reported"
# Stopped by the user: no checks, no reports.
: >"$WORK/curl.log"; : >"$WORK/down.vpn-out"; : >"$WORK/run/stop.requested"
manager tick; manager tick
[ "$(sent_count)" -eq 0 ] || fail "a stopped Prokop was checked"
rm -f "$WORK/run/stop.requested" "$WORK/down.vpn-out"

# --- sing-box down and back ------------------------------------------------
reset
: >"$WORK/clash-down"
manager tick; manager tick
grep -q 'sing-box не отвечает' "$WORK/curl.log" || fail "sing-box down was not reported"
rm -f "$WORK/clash-down"
manager tick
grep -q 'sing-box снова отвечает' "$WORK/curl.log" || fail "sing-box back was not reported"

# --- subscriptions: expiry, traffic, each once ------------------------------
export PROKOP_NOTIFY_NODE_CHECK_SECONDS=100000 PROKOP_NOTIFY_SUBSCRIPTION_CHECK_SECONDS=0
reset
now=$(date +%s)
printf '[{"sourceIndex":1,"expire":%d,"traffic":{"total":107374182400,"remaining":5368709120}}]\n' \
  $((now + 2 * 86400 + 3600)) >"$WORK/meta.vpn"
manager tick
grep -q 'Подписка правила «Main VPN» истекает' "$WORK/curl.log" || fail "the expiry warning is missing"
grep -q 'осталось дней: 2' "$WORK/curl.log" || fail "the days left are missing"
grep -q 'осталось 5% трафика (5.0 ГБ из 100.0 ГБ)' "$WORK/curl.log" || fail "the low traffic warning is missing"
: >"$WORK/curl.log"
manager tick
[ "$(sent_count)" -eq 0 ] || fail "the subscription warnings were repeated"
printf '[{"sourceIndex":1,"expire":%d}]\n' $((now - 60)) >"$WORK/meta.vpn"
manager tick
grep -q 'Подписка правила «Main VPN» истекла' "$WORK/curl.log" || fail "the expiry is missing"
reset
printf '[{"sourceIndex":1,"expire":%d}]\n' $((now + 20 * 86400)) >"$WORK/meta.vpn"
manager tick
[ "$(sent_count)" -eq 0 ] || fail "an expiry far away was reported"

# --- a failed subscription update is queued by the update itself ------------
reset
ucode -L "$LIB" -e 'require("notify.queue").enqueue("subscription", { kind: "subscription_failed", section: "vpn", name: "Main VPN", failed: 1, total: 2 })'
manager flush
grep -q 'Подписка правила «Main VPN» не обновилась (не удалось: 1 из 2)' "$WORK/curl.log" || fail "the update failure text is missing"
grep -q 'require("notify.queue").enqueue("subscription"' "$LIB/subscription/cache.uc" ||
  fail "the subscription update does not queue its failures"

# --- cron line follows the settings ----------------------------------------
reset
printf '0 4 * * * other job\n' >"$WORK/crontab"
manager cron-sync >/dev/null
grep -q "^\* \* \* \* \* $WORK/bin/prokop notify_tick >/dev/null 2>&1 # prokop-notify$" "$WORK/crontab" ||
  fail "the cron line was not written: $(cat "$WORK/crontab")"
grep -q '^0 4 \* \* \* other job$' "$WORK/crontab" || fail "another job was lost"
sed -i '/notify_enabled/d' "$WORK/uci"
manager cron-sync >/dev/null
grep -q prokop-notify "$WORK/crontab" && fail "the cron line stayed while notifications are off"
grep -q '^0 4 \* \* \* other job$' "$WORK/crontab" || fail "another job was lost on removal"
grep -q 'module_capture(NOTIFY_MANAGER_UC, \[ mode \]);' "$LIB/service/lifecycle.uc" ||
  fail "the lifecycle does not keep the cron line in step"

# --- turned off: the queue and outbox are cleared ---------------------------
reset
printf '7' >"$WORK/exit.telegram"; printf '7' >"$WORK/exit.webhook"
record start failure
manager flush
sed -i '/notify_enabled/d' "$WORK/uci"
manager tick
[ "$(jq '.outbox | length' "$WORK/run/notify/state.json")" -eq 0 ] || fail "messages stayed queued after turning off"

echo "notifications: OK"
