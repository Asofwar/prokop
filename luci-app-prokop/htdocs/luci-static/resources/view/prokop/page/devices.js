"use strict";
"require view";
"require form";
"require fs";
"require uci";
"require ui";
"require view.prokop.main as main";
"require view.prokop.shell as shell";
"require view.prokop.configform as configform";

const EntryPoint = view.extend({
  load() {
    return shell.startPage(null);
  },
  render() {
    const map = configform.createMap(
      _("Device routing"),
      _(
        "Select which devices use Prokop. Global bypass cannot be combined with a section kill-switch; use section filters for protected devices.",
      ),
    );
    const s = map.section(form.NamedSection, "settings", "settings");
    let o = s.option(
      form.Flag,
      "alice_mode_enabled",
      _("Enable device policy"),
    );
    o.default = "0";
    o = s.option(form.ListValue, "alice_list_mode", _("Devices in the list"));
    o.value("allow", _("Use Prokop"));
    o.value("deny", _("Bypass Prokop"));
    o.default = "allow";
    o.depends("alice_mode_enabled", "1");
    o.description = _(
      "An empty allow list sends everyone directly. An empty bypass list leaves everyone in Prokop. Bypassed clients get real DNS addresses.",
    );
    for (const [key, label, validator] of [
      [
        "alice_ips",
        "IP addresses and subnets",
        (value) => main.validateSubnet(value).valid,
      ],
      [
        "alice_macs",
        "MAC addresses",
        (value) => /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/i.test(value),
      ],
      [
        "alice_interfaces",
        "Interfaces",
        (value) => /^[A-Za-z0-9_.@-]+\*?$/.test(value),
      ],
    ]) {
      o = s.option(form.DynamicList, key, _(label));
      o.depends("alice_mode_enabled", "1");
      o.retain = true;
      o.validate = (_id, value) =>
        !value || validator(value) || _("Invalid value");
    }
    o = s.option(form.Flag, "gaming_enabled", _("Game console profile"));
    o.default = "0";
    o.description = _(
      "Selected consoles send TCP through the chosen connection and UDP directly. Real DNS addresses are used. Requires a separate device policy and no section kill-switch; this does not guarantee Open NAT.",
    );
    o = s.option(
      form.DynamicList,
      "gaming_ips",
      _("Console IP addresses or subnets"),
    );
    o.depends("gaming_enabled", "1");
    o.retain = true;
    o.datatype = "ipaddr";
    o = s.option(form.ListValue, "gaming_section", _("TCP connection"));
    o.depends("gaming_enabled", "1");
    o.retain = true;
    for (const section of uci.sections("prokop", "section"))
      if (
        ["connection", "proxy", "vpn", "outbound"].includes(section.action) &&
        section.enabled !== "0"
      )
        o.value(section[".name"], section.label || section[".name"]);
    const report = s.option(
      form.DummyValue,
      "_device_report",
      _("Observed devices"),
    );
    report.renderWidget = () => {
      const result = E("div", {}, _("Loading…"));
      fs.exec("/usr/bin/prokop", ["device_policy_status"])
        .then((response) => {
          if (response.code !== 0)
            throw new Error(response.stderr || _("Device report unavailable"));
          const data = JSON.parse(response.stdout);
          if (!data.enabled) {
            result.replaceChildren(
              document.createTextNode(
                _(
                  "Enable and apply the device policy to see routing decisions.",
                ),
              ),
            );
            return;
          }
          const rows = (data.devices || []).map((device) =>
            E("tr", {}, [
              E("td", {}, [
                document.createTextNode(
                  String(device.name || device.hostname || device.mac || ""),
                ),
              ]),
              E("td", {}, [
                document.createTextNode((device.ips || []).join(", ")),
              ]),
              E("td", {}, [
                document.createTextNode(String(device.interface || "")),
              ]),
              E("td", {}, [
                document.createTextNode(String(device.status || "")),
              ]),
              E("td", {}, [
                document.createTextNode(
                  String(device.matched_by || _("Default policy")),
                ),
              ]),
            ]),
          );
          result.replaceChildren(
            E("table", { class: "table" }, [
              E(
                "tr",
                {},
                ["Device", "Addresses", "Interface", "Route", "Reason"].map(
                  (label) => E("th", {}, _(label)),
                ),
              ),
              ...rows,
            ]),
          );
        })
        .catch(() =>
          result.replaceChildren(
            document.createTextNode(_("Device report unavailable")),
          ),
        );
      return result;
    };
    return map.render();
  },
  handleSaveApply: configform.handleSaveApply,
});

return EntryPoint;
