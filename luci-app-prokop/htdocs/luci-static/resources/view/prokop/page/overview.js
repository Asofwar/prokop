"use strict";
"require view";
"require view.prokop.main as main";
"require view.prokop.shell as shell";

// The overview is a summary; the dashboard controller renders its cards.
const EntryPoint = {
  load() {
    return shell
      .detectAccess()
      .then((readonly) => shell.startPage("dashboard").then(() => readonly));
  },

  render() {
    main.DashboardTab.initController();
    return shell.renderPage(_("Overview"), main.DashboardTab.render());
  },

  handleSave: null,
  handleSaveApply: null,
  handleReset: null,
};

return view.extend(EntryPoint);
