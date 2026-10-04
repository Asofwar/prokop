"use strict";
"require baseclass";
"require dom";
"require fs";
"require ui";

const PROKOP_BIN = "/usr/bin/prokop";
// Read-only sessions may run only the environment-clearing wrapper.
const PROKOP_RO = "/usr/libexec/prokop-ro";
const KILL_SWITCH_ACTIONS = ["connection", "proxy", "outbound", "vpn"];
const STATUS_COLORS = {
  ok: "#2e7d32",
  warn: "#ef6c00",
  off: "#757575",
  error: "#c62828",
};

let statusRequest = null;

function loadStatus(force) {
  if (force || !statusRequest) {
    const request = fs.exec(PROKOP_RO, ["killswitch_status"]).then((result) => {
      const text = (result && result.stdout ? result.stdout : "").trim();
      if (!text) {
        throw new Error(
          (result && result.stderr ? result.stderr : "").trim() ||
            _("Empty response"),
        );
      }
      return JSON.parse(text);
    });
    request.catch(() => {
      if (statusRequest === request) {
        statusRequest = null;
      }
    });
    statusRequest = request;
  }

  return statusRequest;
}

function runCommand(command) {
  return fs.exec(PROKOP_BIN, [command]).then((result) => {
    if (!result || result.code !== 0) {
      // The router's own output stays as detail after a translated lead
      // (FE-10).
      const detail = (
        (result && (result.stderr || result.stdout)) ||
        ""
      ).trim();
      throw new Error(
        detail
          ? `${_("The kill-switch action failed")}: ${detail}`
          : _("Command failed"),
      );
    }
    return result;
  });
}

function isKillSwitchAction(action) {
  return KILL_SWITCH_ACTIONS.includes(`${action || "connection"}`);
}

function badge(text, tone) {
  return E(
    "span",
    {
      style: `display: inline-block; padding: 0.1em 0.6em; border-radius: 1em; color: #fff; background: ${STATUS_COLORS[tone] || STATUS_COLORS.off}; font-weight: bold;`,
    },
    [text],
  );
}

function line(label, value) {
  return E("div", { style: "margin: 0.2em 0;" }, [
    E("strong", {}, [`${label}: `]),
    value,
  ]);
}

function formatTime(epoch) {
  const value = Number(epoch);
  if (!value) {
    return _("never");
  }
  return new Date(value * 1000).toLocaleString();
}

function counterValue(status, name) {
  const counter = status && status.counters ? status.counters[name] : null;
  return counter ? Number(counter.packets) || 0 : 0;
}

function stateOf(status) {
  return status && status.state ? status.state : {};
}

function format(template, values) {
  return Object.keys(values).reduce(
    (text, key) => text.split(`{${key}}`).join(`${values[key]}`),
    template,
  );
}

// The page says in the interface language what the router recorded as a
// code with parameters (killswitch/runtime.uc, FE-10). A detail is the
// router's own text, shown as it is; a code this page does not know falls
// back to the English message.
function codedMessage(item, fallback) {
  const p = item && typeof item === "object" ? item : {};
  const keep = _("keeping the previous protection");
  const texts = {
    config_unreadable: () =>
      `${_("The Prokop configuration could not be read")}; ${keep}`,
    runtime_table_missing: () =>
      `${format(_("Prokop runtime table {table} is not present"), p)}; ${keep}`,
    runtime_behind: () =>
      `${_("The runtime does not match the configuration yet")}: ${p.detail}; ${keep}`,
    nft_failed: () =>
      `${_("The firewall policy could not be applied")}: ${p.detail}; ${keep}`,
    teardown_incomplete: () => _("Protection could not be removed completely"),
    unexpected: () => `${_("Unexpected failure")}: ${p.detail}`,
    legacy_adopt_failed: () => format(_("Could not adopt {file}"), p),
    legacy_saved_policy: () =>
      _(
        "Could not remove the saved policy that the first kill-switch build had removed",
      ),
    legacy_nft_incomplete: () =>
      format(
        _("The {product} kill-switch policy {table} could not be removed completely"),
        p,
      ),
    dns_list_failed: () =>
      `${p.detail}; ${_("the previous DNS block list stays in place")}`,
    uncovered_matchers: () =>
      format(
        _(
          "{keyword} keyword, {regex} regex and {inverted} inverted domain matchers cannot be enforced through DNS while Prokop is stopped",
        ),
        p,
      ),
    client_limited: () =>
      format(
        _(
          "{count} domains of client-limited rules are not blocked through DNS (it is shared by all clients); only their IP lists and FakeIP answers are blocked while Prokop is stopped",
        ),
        p,
      ),
    standby_scope: () =>
      `${_("The standby resolver for a dead sing-box blocks the protected names only, not those of the other VPN sections")}: ${p.detail}`,
    standby_unreadable: () =>
      `${_("The standby resolver for a dead sing-box")}: ${p.detail}`,
    standby_client_limited: () =>
      format(
        _(
          "{count} domains of device-limited rules of other VPN sections are not blocked by the standby resolver for a dead sing-box (DNS is shared by all clients)",
        ),
        p,
      ),
    excluded_devices: () =>
      format(
        _(
          "{count} domains of rules with excluded devices are blocked through DNS for the excluded devices as well (it is shared by all clients) while Prokop is stopped",
        ),
        p,
      ),
    dnsmasq_conflict: () =>
      format(
        _(
          "dnsmasq already uses servers file {file}; DNS protection is not attached",
        ),
        p,
      ),
    dnsmasq_legacy: () =>
      format(
        _(
          "dnsmasq still uses the {product} kill-switch servers file {file}, kept while {product} is installed or active; DNS protection is not attached",
        ),
        p,
      ),
    service_start_failed: () =>
      _(
        "The kill-switch service could not be started; DNS will not fail over to the standby resolver if sing-box dies",
      ),
  };
  const text = texts[p.code];
  return text ? text() : `${fallback || ""}`;
}

function messagesBlock(state) {
  const items = [];
  if (state.last_error) {
    items.push(
      E("div", { style: `color: ${STATUS_COLORS.error};` }, [
        E("strong", {}, [`${_("Last error")}: `]),
        `${codedMessage(state.last_error_code, state.last_error)} (${formatTime(state.last_error_at)})`,
      ]),
    );
  }
  const codes = Array.isArray(state.warning_codes) ? state.warning_codes : [];
  (Array.isArray(state.warnings) ? state.warnings : []).forEach(
    (warning, index) => {
      items.push(
        E("div", { style: `color: ${STATUS_COLORS.warn};` }, [
          `⚠ ${codedMessage(codes[index], warning)}`,
        ]),
      );
    },
  );
  return items;
}

function dnsDescription(status) {
  const dns = status && status.dns ? status.dns : {};
  if (dns.managed === false) {
    return badge(_("Not managed (Dont Touch My DHCP)"), "warn");
  }
  if (dns.conflict) {
    return badge(_("Not attached: dnsmasq uses another servers file"), "error");
  }
  if (!dns.armed) {
    return badge(_("Off"), "off");
  }
  if (dns.blocking) {
    return badge(_("Blocking protected domains now"), "warn");
  }
  if (dns.prokop_dns) {
    return badge(_("Armed: DNS currently goes through Prokop"), "ok");
  }
  return badge(_("Armed"), "ok");
}

function standbyDescription(status) {
  if (status.dns_standby) {
    return badge(
      _(
        "In use: sing-box does not answer; names of VPN sections stay blocked, other names use the regular DNS",
      ),
      "warn",
    );
  }
  if (status.service_running) {
    return badge(_("Ready"), "ok");
  }
  return badge(_("Not running"), "error");
}

function renderSectionStatus(section_id, status) {
  const state = stateOf(status);
  const configured = (status.configured || []).includes(section_id);
  const applied = status.active && (state.sections || []).includes(section_id);

  if (!configured && !applied) {
    return E("div", {}, [
      badge(_("Off"), "off"),
      E(
        "div",
        { class: "cbi-value-description" },
        _(
          "Save and apply with the kill-switch enabled. It is installed after the next successful Prokop start or reload.",
        ),
      ),
    ]);
  }

  const children = [];
  if (applied && configured) {
    children.push(badge(_("Protection active"), "ok"));
  } else if (applied) {
    // A reload of a stopped Prokop does not refresh it (D-15, UC-208).
    children.push(
      badge(
        _("Still enforced until the next successful Prokop start or reload"),
        "warn",
      ),
    );
  } else {
    children.push(
      badge(_("Waiting for a successful Prokop start or reload"), "warn"),
    );
  }
  // A deferred subscription (UC-192): its addresses are in the live table,
  // its domains are not known until it is loaded.
  if ((status.unrouted || []).includes(section_id)) {
    children.push(
      E(
        "div",
        { style: `color: ${STATUS_COLORS.warn};` },
        _(
          "The subscription of this section is not loaded yet: Prokop rejects its traffic. The domains blocked while Prokop is stopped are not refreshed until the subscription is loaded.",
        ),
      ),
    );
  }

  if (status.active) {
    children.push(
      line(_("Blocked connections"), `${counterValue(status, section_id)}`),
    );
    const dnsSections =
      state.dns && state.dns.sections ? state.dns.sections : {};
    const dnsSection = dnsSections[section_id];
    if (dnsSection) {
      children.push(
        line(
          _("Domains blocked while Prokop is stopped"),
          `${dnsSection.domains || 0}`,
        ),
      );
      if (dnsSection.uncovered) {
        children.push(
          line(
            _("Keyword/regex matchers without DNS protection"),
            `${dnsSection.uncovered}`,
          ),
        );
      }
      if (dnsSection.client_limited) {
        children.push(
          line(
            _(
              "Domains of device-limited rules not blocked through DNS (shared by all devices)",
            ),
            `${dnsSection.client_limited}`,
          ),
        );
      }
      if (dnsSection.excluded_devices) {
        children.push(
          line(
            _(
              "Domains also blocked for the excluded devices of this section (DNS is shared by all devices)",
            ),
            `${dnsSection.excluded_devices}`,
          ),
        );
      }
      // D-23: the excluded devices resolve them through their own resolver.
      if (dnsSection.excluded_exempt) {
        children.push(
          line(
            _(
              "Domains the excluded devices of this section resolve while Prokop is stopped (through their own resolver)",
            ),
            `${dnsSection.excluded_exempt}`,
          ),
        );
      }
    }
    if (!(state.rule_sections || []).includes(section_id)) {
      children.push(
        E(
          "div",
          { class: "cbi-value-description" },
          _(
            "This section has no IP lists, so it is protected through FakeIP and DNS only.",
          ),
        ),
      );
    }
  }

  return E("div", {}, [...children, ...messagesBlock(state)]);
}

function renderGlobalStatus(status, actions) {
  const state = stateOf(status);
  const configured = status.configured || [];

  let summary;
  if (status.active) {
    summary = badge(
      status.persistent
        ? _("Protection active")
        : _("Active until the next firewall reload"),
      status.persistent ? "ok" : "warn",
    );
  } else if (configured.length > 0) {
    summary = badge(
      _("Waiting for a successful Prokop start or reload"),
      "warn",
    );
  } else {
    summary = badge(_("Off"), "off");
  }

  const children = [summary];
  children.push(
    line(
      _("Protected sections"),
      configured.length > 0 ? configured.join(", ") : _("none"),
    ),
  );

  if (status.active) {
    children.push(
      line(
        _("Prokop runtime"),
        status.prokop_running
          ? badge(_("running: traffic goes through the VPN"), "ok")
          : badge(_("stopped: protected traffic is blocked"), "warn"),
      ),
    );
    children.push(line(_("DNS protection"), dnsDescription(status)));
    children.push(
      line(_("Standby DNS for a failed sing-box"), standbyDescription(status)),
    );
    const dnsState = state.dns || {};
    if (dnsState.domains != null) {
      children.push(
        line(
          _("Domains blocked while Prokop is stopped"),
          `${dnsState.domains} (${_("exceptions")}: ${dnsState.exceptions || 0})`,
        ),
      );
    }
    children.push(
      line(
        _("FakeIP connections rejected"),
        `${counterValue(status, "fakeip")}`,
      ),
    );
    children.push(line(_("Last update"), formatTime(state.updated_at)));
  }

  children.push(...messagesBlock(state));

  if (actions) {
    children.push(E("div", { style: "margin-top: 0.75em;" }, [...actions]));
  }

  return E("div", {}, [...children]);
}

function statusWidget(render) {
  const container = E("div", { class: "prokop-killswitch-status" }, [
    E("em", {}, _("Loading kill-switch status…")),
  ]);

  const refresh = (force) =>
    loadStatus(force)
      .then((status) => {
        dom.content(container, render(status, refresh));
      })
      .catch((error) => {
        dom.content(
          container,
          E("em", {}, [
            _("Kill-switch status is unavailable: %s").format(
              error && error.message ? error.message : `${error}`,
            ),
          ]),
        );
      });

  refresh(false);
  return container;
}

function actionButton(label, style, handler) {
  return E(
    "button",
    {
      class: `cbi-button ${style}`,
      style: "margin-right: 0.5em;",
      click: ui.createHandlerFn(null, handler),
    },
    [label],
  );
}

function globalActions(status, refresh, readonly) {
  if (readonly) {
    return null;
  }

  const buttons = [];
  if ((status.configured || []).length > 0 && status.prokop_running) {
    buttons.push(
      actionButton(_("Re-apply now"), "cbi-button-apply", () =>
        runCommand("killswitch_sync")
          .then(() => refresh(true))
          .catch((error) =>
            ui.addNotification(null, E("p", {}, [`${error.message}`]), "error"),
          ),
      ),
    );
  }
  if (status.active || status.persistent) {
    buttons.push(
      actionButton(_("Remove protection now"), "cbi-button-negative", () => {
        if (
          !window.confirm(
            _(
              "Remove the kill-switch now? Protected traffic will be able to leave directly until Prokop applies it again on the next successful start or reload.",
            ),
          )
        ) {
          return Promise.resolve();
        }
        return runCommand("killswitch_disable")
          .then(() => refresh(true))
          .catch((error) =>
            ui.addNotification(null, E("p", {}, [`${error.message}`]), "error"),
          );
      }),
    );
  }

  return buttons.length > 0 ? buttons : null;
}

function createSectionStatus(section_id) {
  return statusWidget((status) => renderSectionStatus(section_id, status));
}

function createGlobalStatus(readonly) {
  return statusWidget((status, refresh) =>
    renderGlobalStatus(status, globalActions(status, refresh, readonly)),
  );
}

return baseclass.extend({
  KILL_SWITCH_ACTIONS,
  isKillSwitchAction,
  loadStatus,
  createSectionStatus,
  createGlobalStatus,
});
