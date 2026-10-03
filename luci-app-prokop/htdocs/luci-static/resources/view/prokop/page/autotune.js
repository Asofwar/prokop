"use strict";
"require view";
"require view.prokop.main as main";
"require view.prokop.shell as shell";

const EntryPoint = {
  load() {
    return shell
      .detectAccess()
      .then((readonly) => shell.startPage("autotune").then(() => readonly));
  },

  render() {
    main.AutotuneTab.initController();
    return shell.renderPage(_("DPI autotune"), main.AutotuneTab.render());
  },

  handleSave: null,
  handleSaveApply: null,
  handleReset: null,
};

return view.extend(EntryPoint);
