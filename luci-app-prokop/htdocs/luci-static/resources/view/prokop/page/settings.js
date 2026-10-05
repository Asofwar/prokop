"use strict";
"require view";
"require form";
"require view.prokop.shell as shell";
"require view.prokop.settings as settings";
"require view.prokop.notifications as notifications";
"require view.prokop.updates as updates";
"require view.prokop.configform as configform";

const EntryPoint = {
  load() {
    return shell.startPage(null);
  },

  render() {
    const uiCapabilities = shell.uiCapabilities;
    const prokopMap = configform.createMap(_("Settings"), null);
    prokopMap.tabbed = true;
    // The single "settings" UCI section is shown as five tabs; each tab
    // writes only its own options. LuCI keys map tabs by section type, so
    // each tab gets its own type while editing the same "settings" section.
    const settingsTab = (type, title) => {
      const tab = prokopMap.section(form.TypedSection, type, title);
      tab.anonymous = true;
      tab.addremove = false;
      tab.cfgsections = function () {
        return ["settings"];
      };
      return tab;
    };
    settings.createSettingsContent(
      {
        dns: settingsTab("settings_dns", _("DNS")),
        network: settingsTab("settings_network", _("Network")),
        lists: settingsTab("settings_lists", _("Lists and updates")),
        service: settingsTab("settings_service", _("Service settings")),
      },
      uiCapabilities,
    );
    notifications.createNotificationsContent(
      settingsTab("settings_notify", _("Notifications")),
      uiCapabilities,
    );

    const updatesSection = prokopMap.section(
      form.TypedSection,
      "updates",
      _("Components"),
    );
    updatesSection.anonymous = true;
    updatesSection.addremove = false;
    updatesSection.cfgsections = function () {
      return ["updates"];
    };
    updates.createUpdatesContent(updatesSection);

    return prokopMap.render();
  },

  // LuCI's footer calls the view's Save & Apply: snapshot first
  // (configform.js).
  handleSaveApply: configform.handleSaveApply,
};

return view.extend(EntryPoint);
