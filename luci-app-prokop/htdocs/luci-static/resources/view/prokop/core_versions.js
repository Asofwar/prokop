"use strict";
"require baseclass";
"require form";
"require fs";

async function command(args) {
  const response = await fs.exec("/usr/bin/prokop", args);
  if (response.code !== 0)
    throw new Error(response.stderr || response.stdout || _("Command failed"));
  const result = JSON.parse(response.stdout);
  if (result.success === false)
    throw new Error(result.message || _("Command failed"));
  return result;
}
function createCoreVersionContent(section) {
  let option = section.option(
    form.Value,
    "sing_box_pinned_version",
    _("Pinned sing-box-extended version"),
    _(
      "Empty uses the latest release. A pinned tag is used for normal extended updates; other core variants are not version-selectable.",
    ),
  );
  option.validate = (_id, value) =>
    !value ||
    /^v?[0-9][A-Za-z0-9._-]{0,99}$/.test(value) ||
    _("Invalid release tag");
  option = section.option(
    form.DummyValue,
    "_core_versions",
    _("Install a core version"),
  );
  option.renderWidget = function () {
    const select = E("select", { class: "cbi-input-select" }, []);
    const status = E("span", {}, "");
    const install = E(
      "button",
      { type: "button", class: "cbi-button cbi-button-action", disabled: true },
      _("Install selected version"),
    );
    const load = E(
      "button",
      { type: "button", class: "cbi-button" },
      _("Load compatible releases"),
    );
    load.onclick = async () => {
      load.disabled = true;
      status.textContent = _("Loading…");
      try {
        const releases = await command(["core_releases"]);
        select.replaceChildren(
          ...releases.map((release) =>
            E("option", { value: release.tag }, [
              document.createTextNode(String(release.tag)),
            ]),
          ),
        );
        install.disabled = !releases.length;
        status.textContent = releases.length
          ? ""
          : _(
              "No compatible release with a checksum is available from the configured source.",
            );
      } catch (error) {
        status.textContent = String(error.message || error);
      } finally {
        load.disabled = false;
      }
    };
    install.onclick = async () => {
      if (!select.value) return;
      install.disabled = true;
      try {
        const job = await command([
          "component_action_async",
          "sing_box",
          "install_version",
          select.value,
        ]);
        status.textContent = _("Installing…");
        for (let attempt = 0; attempt < 600; attempt++) {
          await new Promise((resolve) => setTimeout(resolve, 1000));
          const state = await command(["component_action_status", job.job_id]);
          status.textContent = String(state.message || _("Installing…"));
          if (!state.running) return;
        }
        status.textContent = _("Still running; check the component status.");
      } catch (error) {
        status.textContent = String(error.message || error);
      } finally {
        install.disabled = false;
      }
    };
    return E("div", {}, [load, select, install, status]);
  };
}
return baseclass.extend({ createCoreVersionContent });
