"use strict";
"require view";
"require view.prokop.main as main";
"require view.prokop.shell as shell";
"require view.prokop.local_devices as localDevices";

const EntryPoint = {
  load() {
    return shell
      .detectAccess()
      .then((readonly) => shell.startPage("diagnostic").then(() => readonly));
  },

  render() {
    main.DiagnosticTab.initController({
      loadLocalDeviceChoices: localDevices.loadLocalDeviceChoices,
    });
    return shell.renderPage(_("Diagnostics"), main.DiagnosticTab.render());
  },

  handleSave: null,
  handleSaveApply: null,
  handleReset: null,
};

return view.extend(EntryPoint);
