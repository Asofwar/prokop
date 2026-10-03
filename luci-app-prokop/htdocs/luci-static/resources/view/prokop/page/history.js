"use strict";
"require view";
"require view.prokop.main as main";
"require view.prokop.shell as shell";

const EntryPoint = {
  load() {
    return shell
      .detectAccess()
      .then((readonly) => shell.startPage("history").then(() => readonly));
  },

  render() {
    main.HistoryTab.initController();
    return shell.renderPage(
      _("History and recovery"),
      main.HistoryTab.render(),
    );
  },

  handleSave: null,
  handleSaveApply: null,
  handleReset: null,
};

return view.extend(EntryPoint);
