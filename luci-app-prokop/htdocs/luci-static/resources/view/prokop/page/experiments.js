"use strict";
"require view";
"require form";
"require fs";
"require uci";
"require view.prokop.main as main";
"require view.prokop.shell as shell";
"require view.prokop.configform as configform";

function text(value) {
  return document.createTextNode(String(value == null ? "" : value));
}
async function command(args) {
  const result = await fs.exec("/usr/bin/prokop", args);
  let data;
  try {
    data = JSON.parse(result.stdout);
  } catch (_) {
    throw new Error(_("Operation failed"));
  }
  if (result.code !== 0 || data.success === false)
    throw new Error(data.reason || data.error || _("Operation failed"));
  return data;
}
function button(label, status, action) {
  const node = E("button", { class: "btn", type: "button" }, [text(label)]);
  node.onclick = async () => {
    node.disabled = true;
    status.textContent = _("Working…");
    try {
      await action();
    } catch (error) {
      status.textContent = String(error.message || error);
    } finally {
      node.disabled = false;
    }
  };
  return node;
}
function widget(section, name, title, render) {
  const option = section.option(form.DummyValue, name, title);
  option.renderWidget = render;
}
const EntryPoint = view.extend({
  load() {
    return shell.startPage(null);
  },
  render() {
    const map = configform.createMap(
      _("Experiments"),
      _(
        "Optional features from community forks. Connectivity recommendations need your review before they change routing.",
      ),
    );
    const section = map.section(form.NamedSection, "settings", "settings");
    widget(section, "_priority_health", _("Node health"), () => {
      const status = E("div");
      const refresh = async () => {
        const data = await command(["priority_health"]);
        if (!data.available) {
          status.textContent = _(
            "Priority health is unavailable or stale. Start a Priority group to collect it.",
          );
          return;
        }
        const rows = [];
        for (const [group, state] of Object.entries(data.groups || {})) {
          for (const [tag, node] of Object.entries(state.nodes || {}))
            rows.push(
              E("tr", {}, [
                E("td", {}, [text(group)]),
                E("td", {}, [text(tag)]),
                E("td", {}, [text(state.active === tag ? _("Active") : "")]),
                E("td", {}, [text(node.handshake)]),
                E("td", {}, [text(node.payload)]),
                E("td", {}, [text(node.delay)]),
                E("td", {}, [text(node.reason)]),
              ]),
            );
        }
        status.replaceChildren(
          E("table", { class: "table" }, [
            E(
              "tr",
              {},
              [
                "Group",
                "Node",
                "Selection",
                "Handshake",
                "Payload",
                "Delay",
                "Reason",
              ].map((label) => E("th", {}, _(label))),
            ),
            ...rows,
          ]),
        );
      };
      return E("div", {}, [
        button(_("Refresh health"), status, refresh),
        status,
      ]);
    });
    widget(section, "_smart_detect", _("Smart Detect"), () => {
      const host = E("input", {
        type: "text",
        placeholder: "example.com",
        maxlength: 253,
      });
      const target = E(
        "select",
        {},
        uci
          .sections("prokop", "section")
          .filter(
            (s) =>
              ["connection", "proxy", "vpn", "outbound"].includes(s.action) &&
              s.enabled !== "0",
          )
          .map((s) =>
            E("option", { value: s[".name"] }, [text(s.label || s[".name"])]),
          ),
      );
      const status = E("div");
      const suggestions = E("div");
      const discover = button(
        _("Find domains in recent error logs"),
        status,
        async () => {
          const data = await command(["smart_detect_status"]);
          suggestions.replaceChildren(
            ...data.candidates.map((domain) => {
              const node = E("button", { type: "button", class: "btn" }, [
                text(domain),
              ]);
              node.onclick = () => {
                host.value = domain;
              };
              return node;
            }),
          );
          status.textContent = data.candidates.length
            ? _("Select an observed domain, then compare paths.")
            : _("No domain candidates in recent error logs.");
        },
      );
      const check = button(_("Compare direct and proxy"), status, async () => {
        const data = await command([
          "smart_detect_run",
          host.value.trim(),
          target.value + "-out",
        ]);
        const record = data.recommendation;
        status.replaceChildren(E("p", {}, [text(JSON.stringify(record))]));
        if (record.confirmed)
          status.appendChild(
            button(_("Add domain to pending changes"), status, async () => {
              const sid = record.target.slice(0, -4);
              if (!uci.get("prokop", sid))
                throw new Error(_("The connection section no longer exists"));
              const existing = uci.get("prokop", sid, "domain_suffix");
              const domains = Array.isArray(existing)
                ? existing.slice()
                : existing
                  ? [existing]
                  : [];
              if (!domains.includes(record.host)) domains.push(record.host);
              uci.set("prokop", sid, "domain_suffix", domains);
              status.textContent = _(
                "Domain added to pending changes. Save & Apply to validate routing and create a rollback snapshot.",
              );
            }),
          );
      });
      return E("div", {}, [
        E(
          "p",
          {},
          _(
            "Enter a domain observed to fail. A recommendation requires two checks at least two minutes apart: direct transport fails while HTTPS through the chosen proxy succeeds. DNS and certificate errors remain inconclusive.",
          ),
        ),
        discover,
        suggestions,
        host,
        target,
        check,
        status,
      ]);
    });
    widget(section, "_profiles", _("Configuration profiles"), () => {
      const name = E("input", {
        type: "text",
        maxlength: 64,
        placeholder: _("Profile name"),
      });
      const select = E("select");
      const status = E("div");
      const refresh = async () => {
        const data = await command(["profiles_list"]);
        select.replaceChildren(
          ...data.profiles.map((p) =>
            E("option", { value: p.name }, [text(p.name)]),
          ),
        );
        status.textContent = _(
          "Profiles use manual snapshots. Removing a name keeps its snapshot in History.",
        );
      };
      return E("div", {}, [
        name,
        button(_("Save current configuration"), status, async () => {
          await command(["profile_save", name.value.trim()]);
          await refresh();
        }),
        select,
        button(_("Refresh profiles"), status, refresh),
        button(_("Compare profile"), status, async () => {
          const data = await command(["profile_diff", select.value]);
          status.replaceChildren(
            E("pre", {}, [text(JSON.stringify(data, null, 2))]),
          );
        }),
        button(_("Activate profile"), status, async () => {
          const data = await command(["profile_activate", select.value]);
          if (
            data.status !== "success" &&
            data.status !== "restored_not_started"
          )
            throw new Error(data.reason || data.status);
          window.location.reload();
        }),
        button(_("Remove profile name"), status, async () => {
          await command(["profile_remove", select.value]);
          await refresh();
        }),
        status,
      ]);
    });
    widget(section, "_support", _("Temporary support access"), () => {
      const key = E("input", {
        type: "password",
        autocomplete: "new-password",
        placeholder: _("Your ephemeral Tailscale auth key"),
      });
      const port = E("select", {}, [
        E("option", { value: "22" }, _("SSH")),
        E("option", { value: "443" }, _("HTTPS administration")),
        E("option", { value: "80" }, _("HTTP administration")),
      ]);
      const status = E("div");
      const refresh = async () => {
        const data = await command(["support_session_status"]);
        status.textContent = data.active
          ? `${data.address.join(", ")} · ${data.remaining_seconds}s · TCP ${data.port}`
          : _("Support access is stopped");
      };
      return E("div", {}, [
        E(
          "p",
          {},
          _(
            "Use a key from your own tailnet with an ephemeral node. One local administration port is available to identities permitted by your tailnet ACL for 30 minutes. Existing SSH or LuCI authentication still applies. The router's existing Tailscale service is independent.",
          ),
        ),
        key,
        port,
        button(_("Start for 30 minutes"), status, async () => {
          const prepared = await command(["support_session_prepare"]);
          await fs.write(prepared.path, key.value.trim());
          key.value = "";
          await command(["support_session_start", port.value]);
          await refresh();
        }),
        button(_("Stop support access"), status, async () => {
          await command(["support_session_stop"]);
          await refresh();
        }),
        button(_("Refresh support status"), status, refresh),
        status,
      ]);
    });
    return map.render();
  },
  handleSaveApply: configform.handleSaveApply,
});

return EntryPoint;
