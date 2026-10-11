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
// The backend answers with reason codes; the page shows them in words.
function reasonText(code) {
  const reasons = {
    invalid_input: _("Invalid value"),
    probe_busy: _("A check is already running."),
    probe_ports_unavailable: _(
      "Local ports 4590 and 4591 are in use; the check cannot start.",
    ),
    runtime_config_unavailable: _(
      "The running configuration is unavailable. Start Prokop first.",
    ),
    invalid_bootstrap_resolver: _(
      "The first bootstrap DNS server must be an IP address.",
    ),
    probe_config_failed: _(
      "The selected connection cannot be checked separately.",
    ),
    probe_config_unsupported: _(
      "The installed sing-box rejected the check configuration.",
    ),
    probe_start_failed: _("The check could not start."),
    probe_not_ready: _("The check could not start."),
    probe_failed: _("The check failed."),
    storage_unavailable: _("Temporary storage is unavailable."),
    result_write_failed: _("Temporary storage is unavailable."),
    profile_storage_unavailable: _("Profile storage is unavailable."),
    profile_operation_busy: _(
      "Another profile operation is running. Try again in a moment.",
    ),
    invalid_profile_index: _("The profile list is damaged."),
    invalid_profile_name: _("Enter a profile name of up to 64 characters."),
    profile_name_exists: _("A profile with this name already exists."),
    profile_not_found: _("Profile not found."),
    profile_index_write_failed: _("The profile list could not be saved."),
    profile_index_write_failed_snapshot_preserved: _(
      "The profile list could not be saved; the snapshot is kept in History.",
    ),
    profile_operation_failed: _("Operation failed"),
    snapshot_operation_failed: _("Operation failed"),
    snapshot_operation_in_progress: _(
      "Another snapshot operation is already in progress. Try again in a moment.",
    ),
    manual_limit_reached: _(
      "The limit of manual snapshots is reached. Delete one in History first.",
    ),
  };
  return reasons[code] || `${_("Operation failed")} (${code})`;
}
async function command(args) {
  const result = await fs.exec("/usr/bin/prokop", args);
  let data;
  try {
    data = JSON.parse(result.stdout);
  } catch {
    throw new Error(_("Operation failed"));
  }
  if (result.code !== 0 || data.success === false) {
    const code = data.reason || data.error || data.status;
    throw new Error(code ? reasonText(String(code)) : _("Operation failed"));
  }
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
        const payloadText = {
          passed: _("Healthy"),
          failed: _("Error"),
          pending: _("Checking now"),
          disabled: _("Not checked"),
        };
        const reasons = {
          handshake_failed: _("The node did not answer the delay check"),
          payload_failed: _("The node did not pass the payload download"),
        };
        const rows = [];
        for (const [group, state] of Object.entries(data.groups || {})) {
          for (const [tag, node] of Object.entries(state.nodes || {}))
            rows.push(
              E("tr", {}, [
                E("td", {}, [text(group)]),
                E("td", {}, [text(tag)]),
                E("td", {}, [
                  text(state.active === tag ? _("Selected node") : ""),
                ]),
                E("td", {}, [text(node.handshake ? _("Healthy") : _("Error"))]),
                E("td", {}, [
                  text(payloadText[node.payload] || _("Not checked")),
                ]),
                E("td", {}, [
                  text(
                    node.handshake && Number(node.delay) > 0
                      ? _("%d ms").format(Number(node.delay))
                      : "",
                  ),
                ]),
                E("td", {}, [
                  text(node.reason ? reasons[node.reason] || node.reason : ""),
                ]),
              ]),
            );
        }
        status.replaceChildren(
          E("table", { class: "table" }, [
            E("tr", {}, [
              E("th", {}, _("Group")),
              E("th", {}, _("Node")),
              E("th", {}, _("Selection")),
              E("th", {}, _("Delay check")),
              E("th", {}, _("Payload download")),
              E("th", {}, _("Delay")),
              E("th", {}, _("Reason")),
            ]),
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
        const verdicts = {
          candidate: _(
            "The direct connection fails while the selected connection works.",
          ),
          direct_works: _(
            "The direct connection works; no change is recommended.",
          ),
          dns_failed: _(
            "The domain could not be resolved; the result is inconclusive.",
          ),
          inconclusive: _("The result is inconclusive."),
          proxy_failed: _(
            "The selected connection does not work for this domain either; no change is recommended.",
          ),
        };
        let summary =
          verdicts[record.verdict] || _("The result is inconclusive.");
        if (record.verdict === "candidate")
          summary +=
            " " +
            (record.confirmed
              ? _("Confirmed by two checks.")
              : _("Repeat the check in two minutes to confirm."));
        status.replaceChildren(
          E("p", {}, [text(`${record.host}: ${summary}`)]),
        );
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
          const show = (value) =>
            value == null
              ? _("(not set)")
              : Array.isArray(value)
                ? value.join(", ")
                : String(value);
          const lines = [];
          for (const change of data.changes || []) {
            if (change.truncated)
              lines.push(
                _("… and more changes, %d in total").format(change.total),
              );
            else
              lines.push(
                `${change.section}.${change.option}: ${show(change.before)} → ${show(change.after)}`,
              );
          }
          status.replaceChildren(
            E("p", {}, [
              text(
                lines.length
                  ? _("Profile value → current value")
                  : _("The profile matches the current configuration."),
              ),
            ]),
            E("pre", {}, [text(lines.join("\n"))]),
          );
        }),
        button(_("Activate profile"), status, async () => {
          const data = await command(["profile_activate", select.value]);
          if (
            data.status !== "success" &&
            data.status !== "restored_not_started"
          )
            throw new Error(reasonText(String(data.reason || data.status)));
          window.location.reload();
        }),
        button(_("Remove profile name"), status, async () => {
          await command(["profile_remove", select.value]);
          await refresh();
        }),
        status,
      ]);
    });
    return map.render();
  },
  handleSaveApply: configform.handleSaveApply,
});

return EntryPoint;
