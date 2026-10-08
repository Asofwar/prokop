"use strict";
"require view";
"require form";
"require fs";
"require uci";
"require view.prokop.shell as shell";
"require view.prokop.configform as configform";

const EntryPoint = view.extend({
  load() {
    return shell.startPage(null);
  },
  render() {
    const map = configform.createMap(
      _("Local providers"),
      _(
        "Run Xray, WDTT (qwdtt) or OlcRTC as a local SOCKS connection. Install the provider binary first. Save & Apply, then start providers; add the displayed socks5 URL to a connection section in Rules. Providers use separate configs and processes.",
      ),
    );
    const s = map.section(form.GridSection, "sidecar", _("Providers"));
    s.anonymous = false;
    s.addremove = true;
    let o = s.option(form.Flag, "enabled", _("Enabled"));
    o.default = "0";
    o = s.option(form.ListValue, "kind", _("Provider"));
    for (const [key, title] of [
      ["xray", "Xray"],
      ["wdtt", "WDTT / qwdtt"],
      ["olcrtc", "OlcRTC"],
    ])
      o.value(key, title);
    o.default = "xray";
    o = s.option(form.Value, "port", _("Local SOCKS port"));
    o.datatype = "range(1024,65535)";
    o.rmempty = false;
    o = s.option(
      form.TextValue,
      "connection_secret",
      _("Connection configuration"),
    );
    o.rows = 6;
    o.modalonly = true;
    o.rmempty = false;
    o.description = _(
      "Xray: one native outbound JSON object. WDTT: qwdtt://config?peer=host:port&hashes=...&pass=... . OlcRTC: olcrtc://provider?transport@room#64-hex-key . The local SOCKS listener is always 127.0.0.1.",
    );
    const controls = map.section(form.NamedSection, "settings", "settings");
    const report = controls.option(
      form.DummyValue,
      "_provider_status",
      _("Provider status"),
    );
    report.renderWidget = () => {
      const output = E("div");
      const run = async (action) => {
        output.textContent = _("Working…");
        try {
          const response = await fs.exec("/usr/bin/prokop", [action]);
          const data = JSON.parse(response.stdout);
          if (response.code !== 0 || data.success === false)
            throw new Error(data.reason || _("Operation failed"));
          output.replaceChildren(
            E("pre", {}, [
              document.createTextNode(JSON.stringify(data, null, 2)),
            ]),
          );
        } catch (error) {
          output.textContent = String(error.message || error);
        }
      };
      const nodes = [
        ["Refresh status", "sidecars_status"],
        ["Start or update providers", "sidecars_apply"],
        ["Stop providers", "sidecars_stop"],
      ].map(([label, action]) => {
        const button = E("button", { type: "button", class: "btn" }, _(label));
        button.onclick = async () => {
          button.disabled = true;
          try {
            await run(action);
          } finally {
            button.disabled = false;
          }
        };
        return button;
      });
      return E("div", {}, [...nodes, output]);
    };
    return map.render();
  },
  handleSaveApply: configform.handleSaveApply,
});

return EntryPoint;
