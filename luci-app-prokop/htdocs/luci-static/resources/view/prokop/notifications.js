"use strict";
"require baseclass";
"require form";
"require fs";
"require uci";
"require view.prokop.main as main";
"require view.prokop.settings as settings";

// The Notifications tab of Settings: Telegram and a webhook (backend
// notify/manager.uc, options notify_* of the settings section). The bot
// token and the webhook URL are secrets: the page never shows them, an
// empty field keeps what is saved, and only the delete box removes it.

const UCI_PACKAGE = main.PROKOP_UCI_PACKAGE;
const PROKOP_BIN = "/usr/bin/prokop";

// The same checks as notify/config.uc: a value the backend would not take
// is refused here.
const TELEGRAM_TOKEN = /^[0-9]{5,16}:[A-Za-z0-9_-]{30,64}$/;
const TELEGRAM_CHAT = /^(-?[0-9]{1,20}|@[A-Za-z0-9_]{5,64})$/;
const WEBHOOK_URL = /^https?:\/\/[\][A-Za-z0-9.:-]+(\/[^ \t\r\n"\\]*)?$/;

function saved(section_id, key) {
  return `${uci.get(UCI_PACKAGE, section_id, key) || ""}`.trim() !== "";
}

// A secret field: never filled from the configuration; a new value replaces
// the saved one, an empty field keeps it, and the box under a saved one
// deletes it on save.
function configureSecret(option, key, pattern, message, example, deleteLabel) {
  const deleteBoxes = {};
  option.password = true;
  option.rmempty = true;
  option.cfgvalue = function () {
    return "";
  };
  option.load = function (section_id) {
    this.placeholder = saved(section_id, key)
      ? _("Saved. Enter a new value to replace it")
      : example;
    return "";
  };
  option.renderWidget = function (section_id) {
    const widget = form.Value.prototype.renderWidget.apply(this, arguments);
    if (!saved(section_id, key)) {
      return widget;
    }
    const box = E("input", { type: "checkbox" });
    deleteBoxes[section_id] = box;
    return E("div", {}, [
      widget,
      E("label", { class: "prokop-notify-delete" }, [box, " ", deleteLabel]),
    ]);
  };
  option.write = function (section_id, value) {
    const normalized = value ? `${value}`.trim() : "";
    if (normalized) {
      uci.set(UCI_PACKAGE, section_id, key, normalized);
    } else if (deleteBoxes[section_id]?.checked) {
      uci.unset(UCI_PACKAGE, section_id, key);
    }
  };
  // An empty field keeps the saved value unless its box is checked.
  option.remove = function (section_id) {
    if (deleteBoxes[section_id]?.checked) {
      uci.unset(UCI_PACKAGE, section_id, key);
    }
  };
  option.validate = function (_section_id, value) {
    const normalized = value ? `${value}`.trim() : "";
    if (
      !normalized ||
      (pattern.test(normalized) && normalized.length <= 1024)
    ) {
      return true;
    }
    return message;
  };
}

const REASONS = {
  token_rejected: () => _("Telegram did not accept the bot token"),
  chat_not_found: () =>
    _("Chat not found: check the ID and that you wrote to the bot first"),
  bot_blocked: () => _("The bot is blocked or was removed from the chat"),
  forbidden: () => _("The bot may not write to this chat"),
  bad_request: () => _("Telegram refused the request"),
  network: () => _("The server could not be reached"),
  local_error: () => _("The request could not be prepared on the router"),
};

function reasonText(reason) {
  const text = `${reason || ""}`;
  const known = REASONS[text];
  if (known) {
    return known();
  }
  const http = text.match(/^http_([0-9]+)$/);
  if (http) {
    return _("The server answered HTTP %s").format(http[1]);
  }
  return _("Not delivered");
}

function channelName(channel) {
  return channel === "telegram" ? "Telegram" : _("Webhook");
}

function resultLines(answer) {
  if (!answer || typeof answer !== "object") {
    return [_("The test could not run")];
  }
  if (answer.reason === "disabled") {
    return [_("Notifications are off: enable them and save the settings")];
  }
  if (answer.reason === "not_configured") {
    return [
      _("No channel is set up: save a bot token and chat ID, or a webhook URL"),
    ];
  }
  const channels = Array.isArray(answer.channels) ? answer.channels : [];
  // An answer without channel results (local_error: the router could not
  // prepare the request) still says why (FE-17).
  if (!channels.length) {
    return [
      answer.reason ? reasonText(answer.reason) : _("The test could not run"),
    ];
  }
  return channels.map((item) => {
    const route =
      item.route === "proxy"
        ? _("through the rule")
        : item.route === "direct"
          ? _("directly")
          : "";
    const verdict =
      item.status === "ok" ? _("Delivered") : reasonText(item.reason);
    return `${channelName(item.channel)}: ${verdict}${route ? ` (${route})` : ""}`;
  });
}

function runTest(output, button) {
  button.disabled = true;
  output.textContent = _("Sending…");
  return fs
    .exec(PROKOP_BIN, ["notify_test"])
    .then((result) => {
      let answer = null;
      try {
        answer = JSON.parse(`${(result && result.stdout) || ""}`.trim());
      } catch (e) {
        answer = null;
      }
      return resultLines(answer);
    })
    .catch(() => [_("The test could not run")])
    .then((lines) => {
      output.textContent = "";
      for (const line of lines) {
        output.appendChild(E("div", {}, [line]));
      }
      button.disabled = false;
    });
}

function createNotificationsContent(section, capabilities) {
  let o = section.option(
    form.Flag,
    "notify_enabled",
    _("Enable notifications"),
    _(
      "Send a message to Telegram or a webhook when Prokop rolls back a change, a connection stops answering, or a subscription fails or ends",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.Value,
    "notify_telegram_token",
    _("Telegram bot token"),
    _(
      "Create a bot with @BotFather and paste its token. The saved token is never shown on the page",
    ),
  );
  o.depends("notify_enabled", "1");
  configureSecret(
    o,
    "notify_telegram_token",
    TELEGRAM_TOKEN,
    _("This does not look like a bot token (123456789:ABC…)"),
    "123456789:ABC…",
    _("Delete the saved token"),
  );

  o = section.option(
    form.Value,
    "notify_telegram_chat_id",
    _("Telegram chat ID"),
    _(
      "Your user ID, a group ID (it starts with -100) or @channel. Write to the bot first, otherwise it cannot write to you",
    ),
  );
  o.depends("notify_enabled", "1");
  o.rmempty = true;
  o.validate = function (_section_id, value) {
    const normalized = value ? `${value}`.trim() : "";
    return !normalized || TELEGRAM_CHAT.test(normalized)
      ? true
      : _("Use a numeric ID or @channel");
  };

  o = section.option(
    form.Value,
    "notify_webhook_url",
    _("Webhook URL"),
    _(
      "A POST to this address, for ntfy, Gotify and similar services. The saved address is never shown on the page",
    ),
  );
  o.depends("notify_enabled", "1");
  configureSecret(
    o,
    "notify_webhook_url",
    WEBHOOK_URL,
    _("Use an http(s) address without spaces or quotes"),
    "https://ntfy.sh/…",
    _("Delete the saved webhook URL"),
  );

  o = section.option(
    form.ListValue,
    "notify_webhook_format",
    _("Webhook format"),
  );
  o.value("json", _("JSON: title, message, priority (Gotify)"));
  o.value("text", _("Plain text (ntfy)"));
  o.default = "json";
  o.rmempty = false;
  o.depends("notify_enabled", "1");

  o = section.option(
    form.Flag,
    "notify_on_rollback",
    _("Rollbacks and failed changes"),
    _("A failed reload, start or snapshot restore, an autotune rollback"),
  );
  o.default = "1";
  o.rmempty = false;
  o.depends("notify_enabled", "1");

  o = section.option(
    form.Flag,
    "notify_on_node",
    _("Connections down"),
    _(
      "A connection rule or sing-box stops answering, and when it is back. Checked every 5 minutes",
    ),
  );
  o.default = "1";
  o.rmempty = false;
  o.depends("notify_enabled", "1");

  o = section.option(
    form.Flag,
    "notify_on_subscription",
    _("Subscriptions"),
    _(
      "A subscription fails to update, is about to expire, has expired or runs out of traffic",
    ),
  );
  o.default = "1";
  o.rmempty = false;
  o.depends("notify_enabled", "1");

  o = section.option(
    form.Value,
    "notify_subscription_expire_days",
    _("Warn before expiry, days"),
  );
  o.datatype = "range(1,30)";
  o.placeholder = "3";
  o.default = "3";
  o.rmempty = false;
  o.depends({ notify_enabled: "1", notify_on_subscription: "1" });
  o.validate = function (_section_id, value) {
    const text = `${value || ""}`.trim();
    return /^[0-9]{1,2}$/.test(text) && +text >= 1 && +text <= 30
      ? true
      : _("Enter a number from 1 to 30");
  };

  o = section.option(
    form.Flag,
    "notify_via_proxy",
    _("Send through a rule"),
    _(
      "Send through the connection of the selected rule, for example when Telegram is blocked. When that does not get through, Prokop sends directly",
    ),
  );
  o.depends("notify_enabled", "1");
  settings.configureDownloadViaProxyFlag(o, "notify_via_proxy_section");

  o = section.option(
    form.ListValue,
    "notify_via_proxy_section",
    _("Send through"),
  );
  o.depends({ notify_enabled: "1", notify_via_proxy: "1" });
  settings.configureDownloadSectionOption(
    o,
    "notify_via_proxy_section",
    capabilities,
  );

  o = section.option(
    form.DummyValue,
    "_notify_test",
    _("Check"),
    _(
      "Sends a test message with the saved settings: save and apply changes first",
    ),
  );
  o.depends("notify_enabled", "1");
  o.renderWidget = function () {
    const output = E("div", { class: "prokop-notify-test-result" });
    const button = E(
      "button",
      {
        class: "cbi-button cbi-button-action",
        type: "button",
        click: (ev) => {
          ev.preventDefault();
          return runTest(output, button);
        },
      },
      [_("Send test")],
    );
    return E("div", {}, [button, output]);
  };
}

return baseclass.extend({
  createNotificationsContent,
  resultLines,
});
