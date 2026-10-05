"use strict";
"require view";
"require view.prokop.main as main";
"require view.prokop.shell as shell";
"require view.prokop.local_devices as localDevices";
"require view.prokop.devices_view as devicesView";

const EntryPoint = {
  load() {
    return shell
      .detectAccess()
      .then((readonly) => shell.startPage("monitoring").then(() => readonly));
  },

  // Connections run the monitoring controller; the Nodes view runs the
  // dashboard controller (node selection).
  render() {
    main.DashboardTab.initController();
    main.MonitoringTab.initController({
      loadLocalDeviceChoices: localDevices.loadLocalDeviceChoices,
      loadLocalDeviceHosts: localDevices.loadLocalDeviceHosts,
      // The Devices table is a module of its own: the other Prokop pages
      // do not load it.
      renderDevicesPanel: devicesView.renderDevicesPanel,
    });
    return shell.renderPage(_("Monitoring"), main.MonitoringTab.render());
  },

  handleSave: null,
  handleSaveApply: null,
  handleReset: null,
};

return view.extend(EntryPoint);
