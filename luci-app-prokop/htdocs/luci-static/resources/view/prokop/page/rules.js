"use strict";
"require view";
"require form";
"require view.prokop.shell as shell";
"require view.prokop.section as section";
"require view.prokop.configform as configform";

// Routing rules: the rules grid with its own Save & Apply.
const EntryPoint = {
  load() {
    return shell.startPage(null);
  },

  render() {
    const loadUiCapabilities = shell.loadUiCapabilities;
    const rulesMap = configform.createMap(_("Rules"), null);

    const rulesSection = rulesMap.section(
      form.GridSection,
      "section",
      null,
      _("Rules are checked from top to bottom. Drag rows to change priority."),
    );
    configform.configureGridSection(
      rulesSection,
      "section",
      _("Rule"),
      _("Add a rule"),
    );
    section.configureSectionSection(rulesSection, {
      loadActionProvidersAvailability: loadUiCapabilities,
    });
    section.createSectionContent(rulesSection);

    return rulesMap.render();
  },
};

return view.extend(EntryPoint);
