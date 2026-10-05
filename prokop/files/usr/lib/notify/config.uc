// The notification settings (options notify_* of the settings section).
//
//   notify_enabled                 '1' turns notifications on
//   notify_telegram_token          Telegram bot token (a secret)
//   notify_telegram_chat_id        chat, group or channel id, or @channel
//   notify_webhook_url             URL a POST goes to (ntfy, Gotify, ...)
//   notify_webhook_format          'json' (title, message, priority) or 'text'
//   notify_via_proxy               '1': send through the connection of
//   notify_via_proxy_section       this rule (sing-box inbound
//                                  service-notify-in, singbox/generator.uc)
//   notify_on_rollback             a failed reload, start or restore, an
//                                  autotune rollback
//   notify_on_node                 a connection or sing-box stops answering
//   notify_on_subscription         a subscription fails to update, expires
//                                  or runs out of traffic
//   notify_subscription_expire_days  warn this many days before expiry
//
// A channel counts only with valid values: a token or URL that does not
// look right is no channel, and the settings page refuses it.

let common = require("core.common");
let uci_core = require("core.uci");

const CONFIG_NAME = getenv("PROKOP_CONFIG_NAME") || "prokop";
const NOTIFY_PROXY_PORT = int(getenv("SB_SERVICE_MIXED_INBOUND_PORT") || "4534") - 1;
const NOTIFY_PROXY_ADDRESS = getenv("SB_SERVICE_MIXED_INBOUND_ADDRESS") || "127.0.0.1";

const CATEGORIES = [ "rollback", "node", "subscription" ];

function as_string(value) {
    return value == null ? "" : "" + value;
}

function valid_telegram_token(value) {
    return match(as_string(value), /^[0-9]{5,16}:[A-Za-z0-9_-]{30,64}$/) != null;
}

function valid_telegram_chat_id(value) {
    value = as_string(value);
    return match(value, /^-?[0-9]{1,20}$/) != null || match(value, /^@[A-Za-z0-9_]{5,64}$/) != null;
}

// http(s), a host, no whitespace, quotes or backslashes: the URL goes into a
// curl config file as a quoted value.
function valid_webhook_url(value) {
    value = as_string(value);
    return length(value) <= 1024 && match(value, /^https?:\/\/[][A-Za-z0-9.:-]+(\/[^ \t\r\n"\\]*)?$/) != null;
}

function expire_days(value) {
    let days = int(as_string(value) || "3");
    return days >= 1 && days <= 30 ? days : 3;
}

function from_section(settings) {
    settings = common.object_or_empty(settings);
    let bool = (key, fallback) => common.bool_option(settings, key, fallback);
    let token = trim(common.option(settings, "notify_telegram_token", ""));
    let chat = trim(common.option(settings, "notify_telegram_chat_id", ""));
    let url = trim(common.option(settings, "notify_webhook_url", ""));
    let format = common.option(settings, "notify_webhook_format", "json") == "text" ? "text" : "json";
    let proxy_section = bool("notify_via_proxy", false) ? common.option(settings, "notify_via_proxy_section", "") : "";
    let config = {
        enabled: bool("notify_enabled", false),
        telegram: valid_telegram_token(token) && valid_telegram_chat_id(chat) ? { token, chat_id: chat } : null,
        webhook: valid_webhook_url(url) ? { url, format } : null,
        proxy: proxy_section != "" ? { section: proxy_section, address: NOTIFY_PROXY_ADDRESS + ":" + NOTIFY_PROXY_PORT } : null,
        categories: {
            rollback: bool("notify_on_rollback", true),
            node: bool("notify_on_node", true),
            subscription: bool("notify_on_subscription", true)
        },
        expire_days: expire_days(common.option(settings, "notify_subscription_expire_days", "3"))
    };
    config.active = config.enabled && (config.telegram != null || config.webhook != null);
    return config;
}

function read() {
    if (!uci_core.load(CONFIG_NAME))
        return from_section({});
    return from_section(uci_core.get_all(CONFIG_NAME, "settings"));
}

// Wanted: notifications are active and the category is on.
function wants(config, category) {
    return config.active && index(CATEGORIES, category) >= 0 && config.categories[category] === true;
}

return {
    CATEGORIES,
    NOTIFY_PROXY_PORT,
    valid_telegram_token,
    valid_telegram_chat_id,
    valid_webhook_url,
    from_section,
    read,
    wants
};
