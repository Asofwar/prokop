"use strict";
"require baseclass";
"require form";
"require ui";
"require uci";
"require fs";
"require view.prokop.main as main";
"require view.prokop.component_progress as componentProgress";

function createUpdatesContent(section) {
  const o = section.option(form.DummyValue, "_mount_node");
  o.rawhtml = true;
  o.cfgvalue = () => {
    // The progress panels of the cards are a module of their own: the
    // other Prokop pages do not load them.
    main.UpdatesTab.initController({
      renderComponentProgress: componentProgress.renderComponentProgress,
      patchComponentProgress: componentProgress.patchComponentProgress,
    });
    return main.UpdatesTab.render();
  };
}

const EntryPoint = {
  createUpdatesContent,
};

return baseclass.extend(EntryPoint);
