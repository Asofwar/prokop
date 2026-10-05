#!/usr/bin/env ucode

// Notifications: Telegram and a generic webhook (ntfy, Gotify, ...).
//
// Modes:
//   flush         send the queued events (notify/queue.uc starts it)
//   tick          flush, then the periodic checks that are due: the
//                 connections and sing-box (every NODE_CHECK_SECONDS), the
//                 subscriptions' expiry and traffic (every
//                 SUBSCRIPTION_CHECK_SECONDS); run by its cron line
//   test          send a test message to every configured channel now and
//                 print the result of each
//   status        what is configured (never a secret) and how the last
//                 delivery went
//   cron-sync     write the cron line while notifications are active,
//   cron-remove   remove it (service/lifecycle.uc, with the other jobs)
//
// Nothing here runs on the paths that change the router: events arrive as
// files (notify/queue.uc), and a sender that hangs or fails holds up only
// itself. Secrets (the bot token, the webhook URL) never reach a command
// line, a log line or an answer: curl reads them from a private config file
// (-K) that is removed after the request.
//
// Delivery: events found together go out as one message. Each event has a
// key; the same key within its window is sent once (a reload that keeps
// failing, a subscription that fails every hour). At most RATE_MAX messages
// go out per RATE_WINDOW seconds; what is held back is counted and the next
// message says so. A channel that failed for a reason that may pass (no
// network, the proxy down, HTTP 429 or 5xx) is retried by the next tick
// until RETRY_SECONDS have passed; a refusal (a wrong token, an unknown
// chat) is not retried and is shown by status.
//
// Routes: "proxy" through the connection of the chosen rule; "system" as the
// router's own traffic goes, through dnsmasq and so through Prokop's rules
// when the host is in one of their lists; "direct" around Prokop: the host
// is resolved by the bootstrap DNS servers of the settings with nslookup
// (not by dnsmasq, whose upstream is sing-box and may answer with FakeIP),
// and curl connects to that real address, which Prokop's output chain does
// not divert. A message that did not get through the proxy or the system
// route for a reason of the network is sent directly: the event may be that
// very connection, or sing-box, going down (NTF-1).

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");
let connections = require("config.connections");
let singbox_constants = require("singbox.constants");
let notify_config = require("notify.config");
let queue = require("notify.queue");
let cron_line = require("core.cron_line");
let core_url = require("core.url");
let core_ip = require("core.ip");

const LIB_DIR = getenv("PROKOP_LIB") || "/usr/lib/prokop";
const BIN = getenv("PROKOP_BIN") || "/usr/bin/prokop";
const CONFIG_NAME = getenv("PROKOP_CONFIG_NAME") || "prokop";
const RUNTIME_DIR = getenv("PROKOP_RUNTIME_STATE_DIR") || "/var/run/prokop";
const NOTIFY_DIR = queue.NOTIFY_DIR;
const QUEUE_DIR = queue.QUEUE_DIR;
const STATE_FILE = NOTIFY_DIR + "/state.json";
const LOCK_FILE = NOTIFY_DIR + "/lock";
const SHUTDOWN_STATE_FILE = RUNTIME_DIR + "/shutdown_correctly";
const STOP_REQUESTED_FILE = getenv("PROKOP_STOP_REQUESTED_FILE") || RUNTIME_DIR + "/stop.requested";
const RELOAD_LOCK_DIR = getenv("PROKOP_RELOAD_LOCK_DIR") || "/var/run/prokop.reload.lock";
const HOSTNAME_FILE = getenv("PROKOP_NOTIFY_HOSTNAME_FILE") || "/proc/sys/kernel/hostname";
const TELEGRAM_API = getenv("PROKOP_NOTIFY_TELEGRAM_API") || "https://api.telegram.org";
const CRONTAB_FILE = getenv("PROKOP_CRONTAB_FILE") || "/etc/crontabs/root";
const CRONTAB = getenv("PROKOP_NOTIFY_CRONTAB") || "crontab";
const TMP_DIR = getenv("TMP_DIR") || "/tmp";
const CRON_MARKER = "# prokop-notify";
// Tests: the health answer as a file, instead of asking the router.
const HEALTH_FIXTURE = getenv("PROKOP_NOTIFY_HEALTH_FILE") || "";
// The bootstrap DNS server sing-box uses when the settings name none
// (singbox/generator.uc).
const DEFAULT_BOOTSTRAP_DNS = "77.88.8.8";
const NSLOOKUP_TIMEOUT = "5";
const FAKEIP_INET4_RANGE = getenv("SB_FAKEIP_INET4_RANGE") || "198.18.0.0/15";
// The subscription keys that were sent survive a reboot here (NTF-7): the
// runtime state is on tmpfs. Written only when one is added or forgotten.
const PERSIST_FILE = getenv("PROKOP_NOTIFY_PERSIST_FILE") || "/etc/prokop/notify-sent.json";

const NODE_CHECK_SECONDS = int(getenv("PROKOP_NOTIFY_NODE_CHECK_SECONDS") || "300");
const SUBSCRIPTION_CHECK_SECONDS = int(getenv("PROKOP_NOTIFY_SUBSCRIPTION_CHECK_SECONDS") || "3600");
// A connection or sing-box counts as down after this many failed checks in
// a row: one lost probe, or a URLTest group switching, is no outage.
const DOWN_AFTER = 2;
const PROBE_TIMEOUT_MS = 5000;
const RATE_WINDOW = 3600;
const RATE_MAX = int(getenv("PROKOP_NOTIFY_RATE_MAX") || "20");
const RETRY_SECONDS = 1800;
const OUTBOX_MAX = 20;
const LOCK_WAIT_MS = 10000;
const CURL_CONNECT_TIMEOUT = "7";
const CURL_MAX_TIME = "15";
// One tick sends for at most this long; what is left waits for the next one
// (NTF-6). A channel that failed for a reason of the network is not tried
// again within the same run.
const DELIVERY_BUDGET_SECONDS = int(getenv("PROKOP_NOTIFY_DELIVERY_BUDGET_SECONDS") || "60");
// Connection probes running at once (each waits up to PROBE_TIMEOUT_MS).
const PROBE_PARALLEL = 4;
// A subscription with less than this share of its traffic left is reported
// once.
const TRAFFIC_LOW_PERCENT = 10;

function as_string(value) {
    return value == null ? "" : "" + value;
}

function now() {
    return int(clock()[0]);
}

function ensure_dir(path) {
    if (fs.stat(path) == null)
        fs.mkdir(path, 0700);
    let st = fs.stat(path);
    return st != null && st.type == "directory" && fs.chmod(path, 0700);
}

function ensure_dirs() {
    return ensure_dir(RUNTIME_DIR) && ensure_dir(NOTIFY_DIR) && ensure_dir(QUEUE_DIR);
}

function run_capture(args) {
    let pipe = fs.popen(common.shell_command(args) + " 2>/dev/null", "r");
    if (!pipe)
        return { status: -1, output: "" };
    let output = pipe.read("all");
    let status = pipe.close();
    return { status: status > 255 ? int(status / 256) : status, output: as_string(output) };
}

function log_message(message, level) {
    system(common.shell_command([ "logger", "-t", "prokop", "[" + (level || "info") + "] Notifications: " + message ]) +
        " >/dev/null 2>&1");
}

function parse_json(text) {
    try {
        return json(as_string(text));
    }
    catch (e) {
        return null;
    }
}

// ---- state -------------------------------------------------------------------

// The sent keys of subscription warnings (expiry, traffic): weeks-long
// windows that must outlast a reboot.
function subscription_keys(sent_keys) {
    let result = {};
    for (let key, sent in common.object_or_empty(sent_keys))
        if (index(key, "subscription_") == 0 && type(sent) == "array")
            result[key] = sent;
    return result;
}

function persisted_keys() {
    let raw = fs.readfile(PERSIST_FILE, 65536);
    return subscription_keys(raw != null ? parse_json(raw) : null);
}

// Written only when the keys changed: a warning sent or forgotten, a window
// that ran out. A write that fails is logged; the keys stay in the runtime
// state.
function persist_keys(state) {
    let sent = subscription_keys(state.sent_keys);
    let text = sprintf("%J\n", sent);
    let current = fs.readfile(PERSIST_FILE, 65536);
    // Nothing to keep and nothing kept: no file (most routers never warn).
    if (current === text || (current == null && length(keys(sent)) == 0))
        return;
    let dir = fs.dirname(PERSIST_FILE);
    if (fs.stat(dir) == null)
        fs.mkdir(dir, 0755);
    let path = sprintf("%s.%d.tmp", PERSIST_FILE, clock()[1]);
    let file = fs.open(path, "w", 0600);
    let ok = file != null && file.write(text) != null;
    if (file != null)
        file.close();
    if (!ok || !fs.rename(path, PERSIST_FILE)) {
        fs.unlink(path);
        log_message("could not keep the sent subscription warnings in " + PERSIST_FILE +
            "; after a reboot they may be sent again", "warn");
    }
}

function load_state() {
    let raw = fs.readfile(STATE_FILE);
    let value = raw == null || length(raw) > 262144 ? null : parse_json(raw);
    value = common.object_or_empty(value);
    // A new boot (the state is on tmpfs): the subscription warnings already
    // sent are not sent again.
    if (raw == null)
        value.sent_keys = { ...common.object_or_empty(value.sent_keys), ...persisted_keys() };
    for (let key in [ "sent_keys", "nodes", "service" ])
        value[key] = common.object_or_empty(value[key]);
    for (let key in [ "sent_times", "outbox" ])
        if (type(value[key]) != "array") value[key] = [];
    value.dropped = int(value.dropped || 0);
    return value;
}

function save_state(state) {
    let path = sprintf("%s.%d.tmp", STATE_FILE, clock()[1]);
    let file = fs.open(path, "w", 0600);
    if (file == null)
        return false;
    let ok = file.write(sprintf("%J\n", state)) != null;
    file.close();
    if (!ok || !fs.chmod(path, 0600) || !fs.rename(path, STATE_FILE)) {
        fs.unlink(path);
        return false;
    }
    return true;
}

// An exclusive flock, released by the kernel when its holder dies.
// Close-on-exec: curl must not keep it.
function take_lock(wait_ms) {
    let file = fs.open(LOCK_FILE, "ae", 0600);
    if (file == null)
        return null;
    for (let waited = 0; ; waited += 100) {
        if (file.lock("xn"))
            return file;
        if (waited >= wait_ms) {
            file.close();
            return null;
        }
        sleep(100);
    }
}

function release_lock(file) {
    if (file != null) {
        file.lock("u");
        file.close();
    }
}

// ---- texts -------------------------------------------------------------------

function hostname() {
    let name = trim(as_string(fs.readfile(HOSTNAME_FILE)));
    return match(name, /^[A-Za-z0-9._-]{1,64}$/) != null ? name : "";
}

function title() {
    let host = hostname();
    return host != "" ? "Prokop · " + host : "Prokop";
}

// A display name from the configuration: printable, at most 64 bytes. The
// cut never splits a UTF-8 character (NTF-3): length and substr count
// bytes, and Telegram refuses a text that is not valid UTF-8, which would
// lose the whole message with every event in it.
function display_name(value) {
    value = replace(as_string(value), /[[:cntrl:]]/g, " ");
    if (length(value) <= 64)
        return value;
    let cut = 64;
    // A continuation byte (10xxxxxx) at the cut: back to the lead byte.
    while (cut > 0 && (ord(value, cut) & 0xC0) == 0x80)
        cut--;
    return substr(value, 0, cut) + "…";
}

function date_text(epoch) {
    let t = localtime(int(epoch));
    return sprintf("%02d.%02d.%04d", t.mday, t.mon, t.year);
}

function bytes_text(value) {
    value = +value;
    if (value >= 1073741824)
        return sprintf("%.1f ГБ", value / 1073741824);
    return sprintf("%.0f МБ", value / 1048576);
}

// The health of the router after a failed change, from what Prokop reports
// on its dashboard (diagnostics/health.uc).
function health_line() {
    let result = HEALTH_FIXTURE != "" ? { status: 0, output: fs.readfile(HEALTH_FIXTURE) } :
        run_capture([ "ucode", "-L", LIB_DIR, LIB_DIR + "/diagnostics/health.uc", "get" ]);
    let health = result.status == 0 ? parse_json(result.output) : null;
    if (type(health) != "object")
        return "Состояние сейчас: не удалось проверить.";
    if (type(health.guard) == "object" && health.guard.active === true)
        return "Состояние сейчас: Ошибка. Активна защитная блокировка DPI-трафика; на странице «Обзор» Prokop подскажет, как её снять.";
    if (health.overall == "ok" || health.overall == "recovered")
        return "Состояние сейчас: Норма.";
    if (health.overall == "transitioning")
        return "Состояние сейчас: Prokop применяет изменения.";
    if (health.overall == "stopped")
        return "Состояние сейчас: Prokop остановлен.";
    return "Состояние сейчас: Ошибка. Подробности на странице «Обзор».";
}

// The line of an event, or null when it is not reported.
function event_text(event) {
    let kind = event.kind, status = event.status;
    let name = display_name(event.name);
    switch (kind) {
    case "reload":
        return status == "failure" ? "⚠️ Перезагрузка Prokop завершилась ошибкой, новые настройки не применены." : null;
    case "start":
        return status == "failure" ? "⛔ Prokop не запустился." : null;
    case "restore":
        if (status == "recovered")
            return "↩️ Восстановить снимок конфигурации не удалось, Prokop вернул прежнюю конфигурацию.";
        if (status == "failure")
            return "⛔ Восстановить снимок конфигурации не удалось, и вернуть прежнюю тоже. Нужна проверка.";
        return null;
    case "autotune_rollback":
        if (status == "success" && event.trigger == "automatic")
            return "↩️ Автотюн откатил стратегию DPI: новая стратегия" +
                (event.candidate ? " (" + display_name(event.candidate) + ")" : "") + " не прошла проверку.";
        if (status == "failure")
            return "⛔ Автотюн не смог откатить стратегию DPI. Нужна проверка.";
        return null;
    case "node_down":
        return "🔴 Подключение «" + name + "» не отвечает.";
    case "node_up":
        return "🟢 Подключение «" + name + "» снова работает.";
    case "service_down":
        return "⛔ sing-box не отвечает, хотя Prokop запущен: правила с подключениями не работают.";
    case "service_up":
        return "🟢 sing-box снова отвечает.";
    case "subscription_failed":
        return "⚠️ Подписка правила «" + name + "» не обновилась" +
            (int(event.total) > 1 ? sprintf(" (не удалось: %d из %d)", int(event.failed), int(event.total)) : "") +
            ". Работают узлы из последнего успешного обновления.";
    case "subscription_expiring": {
        let days = int(event.days);
        return "⏳ Подписка правила «" + name + "» истекает " + date_text(event.expire) +
            (days <= 0 ? " (сегодня)." : sprintf(" (осталось дней: %d).", days));
    }
    case "subscription_expired":
        return "⛔ Подписка правила «" + name + "» истекла " + date_text(event.expire) + ".";
    case "subscription_traffic_low":
        return sprintf("⏳ В подписке правила «%s» осталось %d%% трафика (%s из %s).", name, int(event.percent),
            bytes_text(event.remaining), bytes_text(event.total));
    case "subscription_traffic_exhausted":
        return "⛔ Трафик подписки правила «" + name + "» закончился.";
    }
    return null;
}

// Dedupe: the same key is sent once within its window. Node and sing-box
// events are transitions already; a key per transition still guards a state
// file that was lost.
function event_key(event) {
    let kind = event.kind;
    if (kind == "node_down" || kind == "node_up")
        return [ "node:" + as_string(event.section) + ":" + kind, 60 ];
    if (kind == "service_down" || kind == "service_up")
        return [ kind, 60 ];
    if (kind == "subscription_failed")
        return [ "subfail:" + as_string(event.section), 21600 ];
    if (index(kind, "subscription_") == 0)
        return [ sprintf("%s:%s:%s:%s", kind, as_string(event.section), as_string(event.source),
            as_string(event.mark)), 2592000 ];
    return [ kind + ":" + as_string(event.status), 300 ];
}

// ---- sending ----------------------------------------------------------------

// A value of a curl config file: quoted, with \ and " escaped. The values
// are validated (notify/config.uc) and never hold a line break.
function curl_quote(value) {
    return "\"" + replace(replace(as_string(value), /\\/g, "\\\\"), /"/g, "\\\"") + "\"";
}

function private_file(suffix) {
    for (let attempt = 0; attempt < 8; attempt++) {
        let t = clock();
        let path = sprintf("%s/req.%d.%d.%d.%s", NOTIFY_DIR, t[0], t[1], attempt, suffix);
        let file = fs.open(path, "wx", 0600);
        if (file != null)
            return { path, file };
    }
    return null;
}

function write_private(suffix, text) {
    let item = private_file(suffix);
    if (item == null)
        return null;
    let ok = item.file.write(text) != null;
    item.file.close();
    if (!ok) {
        fs.unlink(item.path);
        return null;
    }
    return item.path;
}

// One request. config_lines: the curl config (url and data, which may hold
// secrets); args: what may be on the command line; proxy: the proxy
// address, or null for none. Returns { code, exit }. No URL globbing: a
// [1-5] or {a,b} in a webhook URL is part of the address, not five
// requests (NTF-4); only http(s), and a redirect (curl follows none here)
// could only go to https.
function curl_request(config_lines, args, proxy) {
    let config_path = write_private("cfg", join("\n", config_lines) + "\n");
    let response_path = config_path != null ? write_private("out", "") : null;
    if (config_path == null || response_path == null) {
        if (config_path != null) fs.unlink(config_path);
        return { exit: -1, code: 0, body: "" };
    }
    let command = [ "curl", "-sS", "--globoff", "--proto", "=http,https", "--proto-redir", "=https",
        "--connect-timeout", CURL_CONNECT_TIMEOUT, "--max-time", CURL_MAX_TIME,
        "-o", response_path, "-w", "%{http_code}", "-K", config_path ];
    if (proxy != null)
        push(command, "-x", "http://" + proxy);
    else
        push(command, "--noproxy", "*");
    for (let arg in args)
        push(command, arg);
    let result = run_capture(command);
    let body = as_string(fs.readfile(response_path, 4096));
    fs.unlink(config_path);
    fs.unlink(response_path);
    // Exactly one HTTP status, or none that can be trusted.
    let code_text = trim(result.output);
    return { exit: result.status, code: match(code_text, /^[0-9]{3}$/) != null ? int(code_text) : -1, body };
}

// ok, or a reason and whether it may pass.
function classify(channel, response) {
    if (response.exit == -1)
        return { status: "failed", reason: "local_error", retry: true };
    if (response.exit != 0)
        return { status: "failed", reason: "network", retry: true };
    let code = response.code;
    if (code < 0)
        return { status: "failed", reason: "bad_response", retry: false };
    if (code >= 200 && code < 300)
        return { status: "ok" };
    if (channel == "telegram") {
        if (code == 401 || code == 404)
            return { status: "failed", reason: "token_rejected", retry: false };
        if (code == 400 || code == 403) {
            let answer = parse_json(response.body);
            let description = type(answer) == "object" ? lc(as_string(answer.description)) : "";
            return { status: "failed", retry: false,
                reason: index(description, "chat not found") >= 0 ? "chat_not_found" :
                    index(description, "blocked") >= 0 || index(description, "kicked") >= 0 ? "bot_blocked" :
                    index(description, "utf-8") >= 0 ? "bad_text" :
                    code == 403 ? "forbidden" : "bad_request" };
        }
    }
    if (code == 429 || code >= 500 || code == 0)
        return { status: "failed", reason: "http_" + code, retry: true };
    return { status: "failed", reason: "http_" + code, retry: false };
}

function channel_url(config, channel) {
    return channel == "telegram" ? TELEGRAM_API : config.webhook.url;
}

function channel_request(config, channel, message) {
    if (channel == "telegram") {
        let text_path = write_private("txt", message.title + "\n\n" + message.text);
        if (text_path == null)
            return { lines: null };
        return {
            lines: [
                "url = " + curl_quote(TELEGRAM_API + "/bot" + config.telegram.token + "/sendMessage"),
                "data-urlencode = " + curl_quote("chat_id=" + config.telegram.chat_id),
                "data-urlencode = " + curl_quote("text@" + text_path),
                "data = \"disable_web_page_preview=true\""
            ],
            args: [],
            cleanup: [ text_path ]
        };
    }
    let webhook = config.webhook;
    let body = webhook.format == "text" ? message.text :
        sprintf("%J", { title: message.title, message: message.text, priority: message.urgent ? 8 : 5 });
    let body_path = write_private("body", body);
    if (body_path == null)
        return { lines: null };
    return {
        lines: [ "url = " + curl_quote(webhook.url), "data-binary = " + curl_quote("@" + body_path) ],
        args: webhook.format == "text" ?
            [ "-H", "Content-Type: text/plain; charset=utf-8", "-H", "Title: Prokop", "-H",
                "Priority: " + (message.urgent ? "high" : "default") ] :
            [ "-H", "Content-Type: application/json" ],
        cleanup: [ body_path ]
    };
}

// ---- resolving around Prokop (the direct route) -----------------------------

function ipv4_number(address) {
    let parts = split(as_string(address), ".");
    if (length(parts) != 4)
        return null;
    let value = 0;
    for (let part in parts) {
        if (match(part, /^[0-9]{1,3}$/) == null || int(part) > 255)
            return null;
        value = value * 256 + int(part);
    }
    return value;
}

function ipv4_in_cidr(address, cidr) {
    let pieces = split(as_string(cidr), "/");
    let value = ipv4_number(address), base = ipv4_number(pieces[0]);
    let bits = int(pieces[1] ?? "32");
    if (value == null || base == null || bits < 0 || bits > 32)
        return false;
    let size = 1;
    for (let i = 0; i < 32 - bits; i++)
        size *= 2;
    return int(value / size) == int(base / size);
}

// An address the direct route may connect to: not a FakeIP of sing-box
// (Prokop's output chain would send it into sing-box), not a unique local
// IPv6 address (the FakeIP IPv6 range is one), not loopback or unspecified.
function usable_address(address) {
    let family = core_ip.ip_family(address);
    if (family == 4)
        return !ipv4_in_cidr(address, FAKEIP_INET4_RANGE) && !ipv4_in_cidr(address, "127.0.0.0/8") &&
            !ipv4_in_cidr(address, "0.0.0.0/8");
    if (family == 6) {
        let lower = lc(address);
        return match(lower, /^f[cd][0-9a-f]{0,2}:/) == null && lower != "::1" && lower != "::";
    }
    return false;
}

// The bootstrap DNS servers of the settings that are plain addresses off the
// router itself (a resolver on the router is dnsmasq or sing-box).
function bootstrap_servers() {
    let result = [];
    let configured = uci_core.get(CONFIG_NAME + ".settings.bootstrap_dns_server");
    if (type(configured) != "array")
        configured = split(trim(as_string(configured)), /[ \t\r\n]+/);
    for (let value in configured) {
        let server = core_url.host(value);
        if (core_ip.valid_ip(server) && usable_address(server) && index(result, server) < 0)
            push(result, server);
    }
    if (length(result) == 0)
        push(result, DEFAULT_BOOTSTRAP_DNS);
    return result;
}

// The answers of BusyBox nslookup (or a full one) after the "Name:" line.
function nslookup_addresses(output) {
    let result = [], name_seen = false;
    for (let line in split(as_string(output), "\n")) {
        line = trim(line);
        if (index(line, "Name:") == 0) {
            name_seen = true;
            continue;
        }
        if (!name_seen)
            continue;
        let matched = match(line, /^Address([ \t]+[0-9]+)?:[ \t]*(.*)$/);
        if (matched == null)
            continue;
        let address = split(trim(as_string(matched[2])), /[ \t]+/)[0];
        if (core_ip.valid_ip(address))
            push(result, address);
    }
    return result;
}

// The real address of the host of url, from the bootstrap DNS servers:
// { address } (null for a host that is an address already), or { error }.
// IPv4 first: the router's IPv6 uplink is less often there.
function resolve_around_prokop(url) {
    let host = core_url.host(url);
    if (host == "")
        return { error: "dns" };
    if (core_ip.valid_ip(host))
        return usable_address(host) ? { address: null } : { error: "dns" };
    if (match(host, /^[A-Za-z0-9._-]{1,253}$/) == null)
        return { error: "dns" };
    for (let server in bootstrap_servers()) {
        let result = run_capture([ "nslookup", "-timeout=" + NSLOOKUP_TIMEOUT, host, server ]);
        let fallback = null;
        // BusyBox exits non-zero for a missing AAAA next to a usable A
        // answer: the answers decide, not the exit status.
        for (let address in nslookup_addresses(result.output)) {
            if (!usable_address(address))
                continue;
            if (core_ip.ip_family(address) == 4)
                return { address };
            fallback ??= address;
        }
        if (fallback != null)
            return { address: fallback };
    }
    return { error: "dns" };
}

// The curl config line that pins the host of url to address.
function resolve_line(url, address) {
    let port = core_url.port(url);
    if (port == "")
        port = core_url.scheme(url) == "http" ? "80" : "443";
    let target = core_ip.ip_family(address) == 6 ? "[" + address + "]" : address;
    return "resolve = " + curl_quote(core_url.host(url) + ":" + port + ":" + target);
}

function send_direct(config, channel, request) {
    let url = channel_url(config, channel);
    let resolved = resolve_around_prokop(url);
    if (resolved.error != null)
        return { status: "failed", reason: resolved.error, retry: true, route: "direct" };
    let lines = resolved.address != null ? [ ...request.lines, resolve_line(url, resolved.address) ] : request.lines;
    let result = classify(channel, curl_request(lines, request.args, null));
    result.route = "direct";
    return result;
}

// Through the proxy when one is set, else as the router's traffic goes;
// directly around Prokop when that did not get through for a reason of the
// network. Returns the result with the route it took.
function send_channel(config, channel, message) {
    let request = channel_request(config, channel, message);
    if (request.lines == null)
        return { status: "failed", reason: "local_error", retry: true };
    let result = classify(channel, curl_request(request.lines, request.args,
        config.proxy != null ? config.proxy.address : null));
    result.route = config.proxy != null ? "proxy" : "system";
    if (result.status != "ok" && result.reason == "network")
        result = send_direct(config, channel, request);
    for (let path in request.cleanup)
        fs.unlink(path);
    return result;
}

function active_channels(config) {
    let result = [];
    if (config.telegram != null) push(result, "telegram");
    if (config.webhook != null) push(result, "webhook");
    return result;
}

// ---- flush -------------------------------------------------------------------

function read_queue() {
    let events = [];
    let names = sort(fs.lsdir(QUEUE_DIR) || []);
    for (let name in names) {
        if (match(name, /\.json$/) == null) {
            // A temporary file of a writer that died.
            let st = fs.stat(QUEUE_DIR + "/" + name);
            if (st != null && now() - st.mtime > 60) fs.unlink(QUEUE_DIR + "/" + name);
            continue;
        }
        let path = QUEUE_DIR + "/" + name;
        let event = parse_json(fs.readfile(path, 8192));
        fs.unlink(path);
        if (type(event) == "object" && type(event.kind) == "string")
            push(events, event);
    }
    return events;
}

function clear_queue() {
    for (let name in fs.lsdir(QUEUE_DIR) || [])
        fs.unlink(QUEUE_DIR + "/" + name);
}

function prune_state(state, t) {
    let keys_kept = {};
    for (let key, sent in state.sent_keys)
        if (type(sent) == "array" && t - int(sent[0]) < int(sent[1]))
            keys_kept[key] = sent;
    state.sent_keys = keys_kept;
    state.sent_times = filter(state.sent_times, (v) => t - int(v) < RATE_WINDOW);
}

// The lines of the events that pass dedupe, in order; the keys are marked
// sent at once (a message that cannot be delivered is retried from the
// outbox, never composed again).
function compose(config, state, events) {
    let t = now();
    let lines = [], urgent = false, rollback = false;
    for (let event in events) {
        if (!notify_config.wants(config, as_string(event.category)))
            continue;
        let text = event_text(event);
        if (text == null)
            continue;
        let key = event_key(event);
        let sent = state.sent_keys[key[0]];
        if (type(sent) == "array" && t - int(sent[0]) < int(sent[1]))
            continue;
        state.sent_keys[key[0]] = [ t, key[1] ];
        if (index(lines, text) < 0)
            push(lines, text);
        if (index(text, "⛔") == 0 || index(text, "🔴") == 0)
            urgent = true;
        if (event.category == "rollback")
            rollback = true;
    }
    if (length(lines) == 0)
        return null;
    let count = length(lines);
    if (rollback)
        push(lines, health_line());
    return { lines, urgent, count };
}

// Oldest first. A channel that failed for a reason of the network (or of
// resolving around Prokop) is not tried again in this run: its other
// messages would wait out the same timeouts (NTF-6). Past the delivery
// budget the rest waits for the next tick. Nothing that waits is lost: a
// message is dropped only past RETRY_SECONDS or on a refusal, and both are
// logged.
function deliver_outbox(config, state) {
    let t = now();
    let started = clock()[0];
    let kept = [];
    let cut = {};
    let channels = active_channels(config);
    for (let item in state.outbox) {
        if (type(item) != "object" || index(channels, item.channel) < 0 || t - int(item.created) > RETRY_SECONDS) {
            if (type(item) == "object" && index(channels, item.channel) >= 0)
                log_message("a message to " + item.channel + " was not delivered in time and is dropped", "warn");
            continue;
        }
        if (cut[item.channel] || clock()[0] - started >= DELIVERY_BUDGET_SECONDS) {
            push(kept, item);
            continue;
        }
        let result = send_channel(config, item.channel, item.message);
        item.attempts = int(item.attempts) + 1;
        state.last = state.last || {};
        state.last[item.channel] = { time: t, status: result.status, reason: result.reason, route: result.route };
        if (result.status == "ok")
            continue;
        if (result.reason == "network" || result.reason == "dns")
            cut[item.channel] = true;
        if (result.retry)
            push(kept, item);
        else
            log_message("a message to " + item.channel + " was refused (" + result.reason + ")", "warn");
    }
    if (length(kept) > OUTBOX_MAX)
        log_message(sprintf("%d undelivered messages are dropped: no more than %d wait for a retry",
            length(kept) - OUTBOX_MAX, OUTBOX_MAX), "warn");
    state.outbox = length(kept) > OUTBOX_MAX ? slice(kept, length(kept) - OUTBOX_MAX) : kept;
}

function enqueue_message(config, state, composed) {
    let t = now();
    if (length(state.sent_times) >= RATE_MAX) {
        state.dropped += composed.count;
        return;
    }
    let lines = composed.lines;
    if (state.dropped > 0) {
        push(lines, sprintf("Пропущено уведомлений из-за ограничения частоты: %d.", state.dropped));
        state.dropped = 0;
    }
    push(state.sent_times, t);
    let message = { title: title(), text: join("\n", lines), urgent: composed.urgent };
    for (let channel in active_channels(config))
        push(state.outbox, { channel, message, created: t, attempts: 0 });
}

function process_events(config, state, events) {
    prune_state(state, now());
    let composed = compose(config, state, events);
    if (composed != null)
        enqueue_message(config, state, composed);
    deliver_outbox(config, state);
}

// ---- periodic checks ------------------------------------------------------

function prokop_should_run() {
    return as_string(fs.readfile(SHUTDOWN_STATE_FILE)) == "0\n" && fs.stat(STOP_REQUESTED_FILE) == null;
}

function reload_busy() {
    try {
        return require("core.runtime_lock").busy(RELOAD_LOCK_DIR);
    }
    catch (e) {
        return false;
    }
}

function section_label(section) {
    let label = trim(common.option(section, "label", ""));
    return label != "" ? label : as_string(section[".name"]);
}

function connection_sections() {
    let result = [];
    for (let section in uci_core.section_objects(CONFIG_NAME, "section"))
        if (common.bool_option(section, "enabled", true) &&
            connections.is_connections_action(common.option(section, "action", "")))
            push(result, section);
    return result;
}

function clash(args) {
    let command = [ BIN, "clash_api" ];
    for (let arg in args) push(command, arg);
    let result = run_capture(command);
    return { status: result.status, value: parse_json(result.output) };
}

// "up", "down" or "unknown" (the controller did not answer the test), from
// the answer of clash_api get_proxy_latency.
function probe_result(status, value) {
    if (status == 0 && type(value) == "object" && +value.delay > 0)
        return "up";
    if (type(value) == "object" && value.error == "latency_failed")
        return "down";
    return "unknown";
}

// The probes of tags, PROBE_PARALLEL at a time: one after another, ten
// connections that do not answer would hold the tick for 50 s. Each probe
// writes its answer and exit status to a private file. Returns tag ->
// result.
function probe_all(tags) {
    let results = {};
    for (let start = 0; start < length(tags); start += PROBE_PARALLEL) {
        let batch = slice(tags, start, start + PROBE_PARALLEL);
        let jobs = [], script = "";
        for (let tag in batch) {
            let item = private_file("probe");
            if (item == null) {
                results[tag] = "unknown";
                continue;
            }
            item.file.close();
            push(jobs, { tag, path: item.path });
            script += "(" + common.shell_command([ BIN, "clash_api", "get_proxy_latency", tag, "" + PROBE_TIMEOUT_MS ]) +
                " >" + common.shell_quote(item.path) + " 2>/dev/null; echo \"$?\" >" +
                common.shell_quote(item.path + ".rc") + ") </dev/null & ";
        }
        if (length(jobs) > 0)
            system(script + "wait");
        for (let job in jobs) {
            let rc = trim(as_string(fs.readfile(job.path + ".rc", 16)));
            results[job.tag] = probe_result(rc == "" ? -1 : int(rc), parse_json(fs.readfile(job.path, 65536)));
            fs.unlink(job.path);
            fs.unlink(job.path + ".rc");
        }
    }
    return results;
}

function node_check(config, state, events) {
    if (!notify_config.wants(config, "node")) {
        state.nodes = {};
        state.service = {};
        return;
    }
    // Stopped by the user, or a change in progress: nothing to report, and
    // nothing counts towards a failure.
    if (!prokop_should_run() || reload_busy())
        return;
    let proxies = clash([ "get_proxies" ]);
    let service = state.service;
    if (proxies.status != 0 || type(proxies.value) != "object" || type(proxies.value.proxies) != "object") {
        service.fails = int(service.fails) + 1;
        if (service.fails >= DOWN_AFTER && !service.down) {
            service.down = true;
            push(events, { category: "node", kind: "service_down" });
        }
        return;
    }
    if (service.down)
        push(events, { category: "node", kind: "service_up" });
    state.service = {};
    let seen = {};
    let checked = [];
    for (let section in connection_sections()) {
        let tag = singbox_constants.outbound_tag(as_string(section[".name"]));
        if (type(proxies.value.proxies[tag]) == "object")
            push(checked, { section, tag });
    }
    let results = probe_all(map(checked, (item) => item.tag));
    for (let item in checked) {
        let section = item.section;
        let name = as_string(section[".name"]);
        seen[name] = true;
        let node = common.object_or_empty(state.nodes[name]);
        let result = results[item.tag] ?? "unknown";
        if (result == "up") {
            if (node.down)
                push(events, { category: "node", kind: "node_up", section: name, name: section_label(section) });
            node = {};
        }
        else if (result == "down") {
            node.fails = int(node.fails) + 1;
            if (node.fails >= DOWN_AFTER && !node.down) {
                node.down = true;
                push(events, { category: "node", kind: "node_down", section: name, name: section_label(section) });
            }
        }
        state.nodes[name] = node;
    }
    for (let name in keys(state.nodes))
        if (!seen[name])
            delete state.nodes[name];
}

function subscription_sections() {
    let result = [];
    for (let section in connection_sections())
        if (length(connections.subscription_urls(section)) > 0)
            push(result, section);
    return result;
}

// The traffic warnings of a source are sent once per period: a key holds the
// total and the expiry, and is forgotten once the traffic is no longer low
// (a renewal with the same total and no expiry date, NTF-7).
function forget_traffic_keys(state, base) {
    for (let kind in [ "subscription_traffic_low", "subscription_traffic_exhausted" ]) {
        let prefix = sprintf("%s:%s:%s:", kind, base.section, as_string(base.source));
        for (let key in keys(state.sent_keys))
            if (index(key, prefix) == 0)
                delete state.sent_keys[key];
    }
}

function subscription_check(config, state, events) {
    // Like the connection checks: nothing while Prokop is stopped (its cron
    // line may be there for a retry only).
    if (!notify_config.wants(config, "subscription") || !prokop_should_run())
        return;
    let t = now();
    let warn_seconds = config.expire_days * 86400;
    for (let section in subscription_sections()) {
        let name = as_string(section[".name"]);
        let result = run_capture([ BIN, "get_subscription_metadata", name ]);
        let items = result.status == 0 ? parse_json(result.output) : null;
        if (type(items) == "object")
            items = [ items ];
        if (type(items) != "array")
            continue;
        for (let item in items) {
            if (type(item) != "object")
                continue;
            let source = int(item.sourceIndex || 1);
            let base = { category: "subscription", section: name, name: section_label(section), source };
            let expire = int(item.expire || 0);
            if (expire > 0) {
                if (expire <= t)
                    push(events, { ...base, kind: "subscription_expired", expire, mark: expire });
                else if (expire - t <= warn_seconds) {
                    let days = int((expire - t) / 86400);
                    // Once at the configured warning, once more on the last day.
                    push(events, { ...base, kind: "subscription_expiring", expire, days,
                        mark: sprintf("%d:%s", expire, days < 1 ? "last" : "first") });
                }
            }
            let traffic = common.object_or_empty(item.traffic);
            let total = +traffic.total;
            if (total > 0 && traffic.remaining != null) {
                let remaining = +traffic.remaining;
                let mark = sprintf("%d:%d", total, expire);
                if (remaining <= 0)
                    push(events, { ...base, kind: "subscription_traffic_exhausted", mark });
                else if (remaining * 100 / total < TRAFFIC_LOW_PERCENT)
                    push(events, { ...base, kind: "subscription_traffic_low", total, remaining,
                        percent: int(remaining * 100 / total), mark });
                else
                    forget_traffic_keys(state, base);
            }
        }
    }
}

// ---- modes -----------------------------------------------------------------

function flush(with_checks) {
    if (!ensure_dirs())
        return 1;
    let lock = take_lock(with_checks ? 0 : LOCK_WAIT_MS);
    if (lock == null)
        return 0;
    let config = notify_config.read();
    let state = load_state();
    if (!config.active) {
        clear_queue();
        state.outbox = [];
        state.nodes = {};
        state.service = {};
        save_state(state);
        release_lock(lock);
        return 0;
    }
    let events = read_queue();
    if (with_checks) {
        let t = now();
        if (t - int(state.node_checked) >= NODE_CHECK_SECONDS - 5) {
            state.node_checked = t;
            node_check(config, state, events);
        }
        if (t - int(state.subscription_checked) >= SUBSCRIPTION_CHECK_SECONDS - 5) {
            state.subscription_checked = t;
            subscription_check(config, state, events);
        }
    }
    process_events(config, state, events);
    persist_keys(state);
    save_state(state);
    release_lock(lock);
    return 0;
}

function test() {
    let config = notify_config.read();
    let channels = active_channels(config);
    if (!config.enabled)
        return { status: "failed", reason: "disabled", channels: [] };
    if (length(channels) == 0)
        return { status: "failed", reason: "not_configured", channels: [] };
    if (!ensure_dirs())
        return { status: "failed", reason: "local_error", channels: [] };
    let message = { title: title(), text: "✅ Тестовое уведомление. Если вы его видите, уведомления Prokop настроены.",
        urgent: false };
    let results = [];
    let ok = true;
    let lock = take_lock(LOCK_WAIT_MS);
    let state = lock != null ? load_state() : null;
    for (let channel in channels) {
        let result = send_channel(config, channel, message);
        push(results, { channel, status: result.status, reason: result.reason, route: result.route });
        if (result.status != "ok")
            ok = false;
        if (state != null) {
            state.last = state.last || {};
            state.last[channel] = { time: now(), status: result.status, reason: result.reason, route: result.route };
        }
    }
    if (state != null)
        save_state(state);
    release_lock(lock);
    return ok ? { status: "ok", channels: results } : { status: "failed", reason: "delivery_failed", channels: results };
}

function status() {
    let config = notify_config.read();
    let state = load_state();
    let last = {};
    for (let channel, item in common.object_or_empty(state.last))
        if (index([ "telegram", "webhook" ], channel) >= 0 && type(item) == "object")
            last[channel] = { time: int(item.time), status: as_string(item.status), reason: item.reason ?? null,
                route: item.route ?? null };
    let down = [];
    for (let name, node in state.nodes)
        if (type(node) == "object" && node.down) push(down, name);
    return {
        enabled: config.enabled,
        active: config.active,
        channels: { telegram: config.telegram != null, webhook: config.webhook != null },
        via_proxy: config.proxy != null,
        categories: config.categories,
        pending: length(state.outbox),
        last,
        nodes_down: down,
        service_down: state.service?.down === true
    };
}

function cron_write(enabled) {
    let result = cron_line.rewrite({ crontab_file: CRONTAB_FILE, crontab: CRONTAB, tmp_dir: TMP_DIR }, CRON_MARKER,
        enabled ? "* * * * * " + BIN + " notify_tick >/dev/null 2>&1" : null);
    if (result.status == "failed")
        log_message("could not update the schedule line in " + CRONTAB_FILE + ": " + result.reason, "error");
    return result;
}

let mode = ARGV[0] || "";
if (mode == "flush")
    exit(flush(false));
if (mode == "tick")
    exit(flush(true));
let output;
if (mode == "test")
    output = test();
else if (mode == "status")
    output = status();
else if (mode == "cron-sync")
    output = cron_write(notify_config.read().active);
else if (mode == "cron-remove")
    output = cron_write(false);
else if (mode == "fixture-text") {
    let event = parse_json(ARGV[1]);
    print(as_string(type(event) == "object" ? event_text(event) : ""), "\n");
    exit(0);
}
else {
    warn("Usage: notify/manager.uc flush|tick|test|status|cron-sync|cron-remove\n");
    exit(2);
}
print(sprintf("%J\n", output));
// status answers what it found; test and the cron line succeed only with
// "ok" (a failure says why in reason).
exit(mode == "status" || output.status == "ok" ? 0 : 1);
