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
# a request through the proxy uses $WORK/proxy-exit when it exists, one as
# the router's traffic goes (no proxy, no pinned address: through dnsmasq,
# and so through sing-box) $WORK/system-exit.
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
if [ -z "\$proxy" ] && ! grep -q '^resolve = ' "\$cfg" && [ -e "$WORK/system-exit" ]; then
  exit "\$(cat "$WORK/system-exit")"
fi
if [ -e "$WORK/exit.\$channel" ]; then exit "\$(cat "$WORK/exit.\$channel")"; fi
[ -e "$WORK/body.\$channel" ] && cp "$WORK/body.\$channel" "\$out"
printf '%s' "\$(cat "$WORK/code.\$channel" 2>/dev/null || echo 200)"
SH
# nslookup as BusyBox prints it: the router's own resolver (127.0.0.1, which
# is dnsmasq and then sing-box) answers with a FakeIP address, any other
# server with the real one ($WORK/dns.<server> overrides it);
# $WORK/no-nslookup stands for a router without it. Like BusyBox, it exits
# non-zero for the missing AAAA answer.
cat >"$WORK/bin/nslookup" <<SH
#!/bin/sh
echo "\$*" >>"$WORK/nslookup.log"
[ -e "$WORK/no-nslookup" ] && exit 127
host="\$2"; server="\$3"
case "\$server" in
  127.0.0.1) address=198.18.0.7 ;;
  *) address="\$(cat "$WORK/dns.\$server" 2>/dev/null || true)" ;;
esac
if [ -z "\$address" ]; then
  case "\$host" in
    api.telegram.org) address=149.154.167.220 ;;
    *) address=203.0.113.7 ;;
  esac
fi
printf 'Server:\t\t%s\nAddress:\t%s:53\n\nNon-authoritative answer:\nName:\t%s\nAddress: %s\n\n' \
  "\$server" "\$server" "\$host" "\$address"
exit 1
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
  PROKOP_HISTORY_FILE="$WORK/history.jsonl" PROKOP_NOTIFY_NO_FLUSH=1 \
  PROKOP_NOTIFY_PERSIST_FILE="$WORK/persist/notify-sent.json"
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
    "$WORK"/body.* "$WORK/proxy-exit" "$WORK"/down.* "$WORK/clash-down" "$WORK"/meta.* "$WORK/history.jsonl" \
    "$WORK/system-exit" "$WORK"/dns.* "$WORK/no-nslookup" "$WORK/nslookup.log" "$WORK/persist" "$WORK/crontab"
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

# --- the direct route goes around Prokop's DNS and FakeIP (NTF-1) -----------
# The router's resolver (dnsmasq, whose upstream is sing-box) answers with a
# FakeIP address for a host in a rule's list: a request as the router's
# traffic goes then reaches sing-box (simulated: it fails). The direct route
# resolves with the bootstrap DNS server of the settings and pins curl to
# the real address.
reset
setting bootstrap_dns_server 9.9.9.9
printf '7' >"$WORK/system-exit"
record start failure
manager flush
grep -q '^resolve = "api.telegram.org:443:149.154.167.220"$' "$WORK/curl.log" ||
  fail "the direct route does not use the real address: $(grep -e '^resolve' -e '^PROXY' "$WORK/curl.log")"
grep -q '^resolve = "ntfy.example:443:203.0.113.7"$' "$WORK/curl.log" || fail "the webhook host is not pinned"
grep -q 'api.telegram.org 9.9.9.9$' "$WORK/nslookup.log" || fail "not resolved by the bootstrap server: $(cat "$WORK/nslookup.log")"
grep -q ' 127\.0\.0\.1$' "$WORK/nslookup.log" && fail "the direct route asked the router's own resolver"
grep -q '198\.18\.' "$WORK/curl.log" && fail "a FakeIP address was used"
[ "$(jq '.outbox | length' "$WORK/run/notify/state.json")" -eq 0 ] || fail "the direct route did not deliver"
status="$(manager status)"
[ "$(printf '%s' "$status" | jq -r .last.telegram.route)/$(printf '%s' "$status" | jq -r .last.telegram.status)" = direct/ok ] ||
  fail "status does not say the message went directly: $status"
if grep -q -e "$TOKEN" -e 'prokop-secret-topic' "$WORK/argv.log" "$WORK/nslookup.log"; then
  fail "a secret reached a command line"
fi
# A route that works as the router's traffic goes is not doubled.
reset
record start failure
manager flush
[ "$(sent_count)" -eq 2 ] || fail "a working route was retried directly: $(sent_count)"
grep -q '^resolve' "$WORK/curl.log" && fail "the first attempt must go as the router's traffic goes"
[ "$(manager status | jq -r .last.telegram.route)" = system ] || fail "the first route is not named system"
[ -e "$WORK/nslookup.log" ] && fail "nothing needed resolving"
# Without the settings' server: sing-box's default bootstrap server.
reset
printf '7' >"$WORK/system-exit"
record start failure
manager flush
grep -q 'api.telegram.org 77.88.8.8$' "$WORK/nslookup.log" || fail "the default bootstrap server is not used"
# Only FakeIP (a bootstrap server that is the router's resolver after all):
# not sent to that address; the reason is dns, and the message waits.
reset
setting bootstrap_dns_server 192.168.1.1
printf '198.18.0.9' >"$WORK/dns.192.168.1.1"
printf '7' >"$WORK/system-exit"
record start failure
manager flush
grep -q '^resolve' "$WORK/curl.log" && fail "a FakeIP answer was used"
[ "$(manager status | jq -r .last.telegram.reason)" = dns ] || fail "a failed resolution is not reason dns"
[ "$(jq '.outbox | length' "$WORK/run/notify/state.json")" -eq 2 ] || fail "the message does not wait for a retry"
# No nslookup on the router: dns, no crash.
reset
: >"$WORK/no-nslookup"
printf '7' >"$WORK/system-exit"
record start failure
manager flush
[ "$(manager status | jq -r .last.webhook.reason)" = dns ] || fail "a missing nslookup is not reason dns"
# The proxy route that fails goes directly as well, around Prokop.
reset
setting notify_via_proxy 1
setting notify_via_proxy_section vpn
printf '7' >"$WORK/proxy-exit"
record start failure
manager flush
[ "$(grep -c '^resolve = ' "$WORK/curl.log")" -eq 2 ] || fail "the fallback of the proxy route is not around Prokop"

# --- curl: no globbing, http(s) only, one status code (NTF-4) ----------------
reset
sed -i "s|^prokop.settings.notify_webhook_url=.*|prokop.settings.notify_webhook_url=https://ntfy.example/hook[1-5]|" "$WORK/uci"
record start failure
manager flush
grep -q -- '--globoff' "$WORK/argv.log" || fail "curl globs the URL"
grep -q -- '--proto =http,https' "$WORK/argv.log" || fail "curl may use other protocols"
grep -q -- '--proto-redir =https' "$WORK/argv.log" || fail "a redirect may leave https"
reset
printf '200200200' >"$WORK/code.webhook"
record start failure
manager flush
[ "$(manager status | jq -r .last.webhook.reason)" = bad_response ] || fail "a status that is not one code was taken: $(manager status)"
[ "$(jq '[.outbox[] | select(.channel=="webhook")] | length' "$WORK/run/notify/state.json")" -eq 0 ] ||
  fail "a garbled status is retried"

# --- a long name is cut on a character boundary (NTF-3) ---------------------
name="ABC$(printf 'Подключение%.0s' 1 2 3 4 5 6)"
text="$(manager fixture-text "{\"kind\":\"node_down\",\"name\":\"$name\"}")"
printf '%s' "$text" | node -e 'new TextDecoder("utf-8", { fatal: true }).decode(require("fs").readFileSync(0))' ||
  fail "a cut name is not valid UTF-8: $text"
printf '%s' "$text" | grep -q '…' || fail "the long name was not cut"
reset
printf '400' >"$WORK/code.telegram"
printf '{"ok":false,"description":"Bad Request: text must be encoded in UTF-8"}' >"$WORK/body.telegram"
out="$(manager test || true)"
[ "$(printf '%s' "$out" | jq -r '.channels[] | select(.channel=="telegram") | .reason')" = bad_text ] ||
  fail "a text Telegram refused as UTF-8 is not named: $out"

# --- a channel that cannot be reached is tried once per run (NTF-6) ----------
reset
printf '7' >"$WORK/exit.telegram"
record start failure
manager flush
record reload failure
: >"$WORK/curl.log"
manager flush
# Two messages wait for Telegram: the first one fails for the network, the
# second is not tried (the webhook still gets it).
[ "$(grep -c 'CHANNEL telegram' "$WORK/curl.log")" -eq 2 ] ||
  fail "a channel without network was tried more than once: $(grep -c 'CHANNEL telegram' "$WORK/curl.log")"
[ "$(grep -c 'Перезагрузка Prokop завершилась ошибкой' "$WORK/curl.log")" -eq 1 ] ||
  fail "a channel without network was tried for every message"
[ "$(jq '[.outbox[] | select(.channel=="telegram")] | length' "$WORK/run/notify/state.json")" -eq 2 ] ||
  fail "the messages not tried were lost"
# Past the delivery budget the rest waits.
: >"$WORK/curl.log"
rm -f "$WORK/exit.telegram"
PROKOP_NOTIFY_DELIVERY_BUDGET_SECONDS=0 manager flush
[ "$(sent_count)" -eq 0 ] || fail "a run sent past its budget"
[ "$(jq '.outbox | length' "$WORK/run/notify/state.json")" -eq 2 ] || fail "the messages past the budget were lost"
manager flush
[ "$(jq '.outbox | length' "$WORK/run/notify/state.json")" -eq 0 ] || fail "the waiting messages were not sent later"

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

# --- subscription warnings outlast a reboot; a renewal warns again (NTF-7) ---
reset
manager tick
[ -e "$WORK/persist/notify-sent.json" ] && fail "the kept keys file was written with nothing to keep"
printf '[{"sourceIndex":1,"expire":%d,"traffic":{"total":107374182400,"remaining":5368709120}}]\n' \
  $((now + 2 * 86400 + 3600)) >"$WORK/meta.vpn"
manager tick
[ "$(sent_count)" -eq 2 ] || fail "the warnings were not sent: $(sent_count)"
[ "$(stat -c %a "$WORK/persist/notify-sent.json")" = 600 ] || fail "the kept keys are not private"
# A reboot: the runtime state on tmpfs is gone.
rm -rf "$WORK/run/notify"
: >"$WORK/curl.log"
manager tick
[ "$(sent_count)" -eq 0 ] || fail "a reboot sent the subscription warnings again"
# Renewed with the same total and no expiry date: the traffic is fine, then
# low again: warned again.
printf '[{"sourceIndex":1,"traffic":{"total":107374182400,"remaining":5368709120}}]\n' >"$WORK/meta.vpn"
manager tick
printf '[{"sourceIndex":1,"traffic":{"total":107374182400,"remaining":107374182400}}]\n' >"$WORK/meta.vpn"
manager tick
: >"$WORK/curl.log"
printf '[{"sourceIndex":1,"traffic":{"total":107374182400,"remaining":5368709120}}]\n' >"$WORK/meta.vpn"
manager tick
grep -q 'осталось 5% трафика' "$WORK/curl.log" || fail "a renewed subscription is not warned again"

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
