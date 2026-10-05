"use strict";
"require baseclass";
"require form";
"require uci";
"require view.prokop.main as main";
"require view.prokop.notifications as notifications";

// The TorrServer tab of Settings: a password for the API of the TorrServer
// that Prokop installed, and procd's jail for it (options torrserver_* of
// the settings section, both off by default). /etc/init.d/prokop-torrserver
// applies them and restarts TorrServer only when they change; a password
// or a jail that cannot be set up stops TorrServer instead of running it
// open or unjailed. The password is a secret: the page never shows it, an
// empty field keeps it, and only the delete box removes it.

const UCI_PACKAGE = main.PROKOP_UCI_PACKAGE;

// The same checks as torrserver/manager.uc auth(): no colon in the user
// name (HTTP Basic auth splits there), no control character anywhere.
const USER_NAME = /^[A-Za-z0-9._@-]{1,64}$/;
// eslint-disable-next-line no-control-regex
const PASSWORD = /^[^\x00-\x1f\x7f]{1,128}$/;

function savedPassword(section_id) {
  return (
    `${uci.get(UCI_PACKAGE, section_id, "torrserver_auth_password") || ""}` !==
    ""
  );
}

function createTorrServerContent(section, capabilities) {
  const authOption = section.option(
    form.Flag,
    "torrserver_auth_enabled",
    _("Protect TorrServer with a password"),
    _(
      "TorrServer's web page and API then ask for this user name and password, also apps that use its API (Lampa, MSX); stream and playlist links stay open. Applies to the TorrServer that Prokop installed",
    ),
  );
  authOption.default = "0";
  authOption.rmempty = false;

  let o = section.option(
    form.Value,
    "torrserver_auth_user",
    _("TorrServer user name"),
  );
  o.depends("torrserver_auth_enabled", "1");
  o.placeholder = "admin";
  o.rmempty = true;
  o.validate = function (_section_id, value) {
    return USER_NAME.test(value ? `${value}`.trim() : "")
      ? true
      : _("Use 1 to 64 Latin letters, digits, dots, dashes, _ or @");
  };
  notifications.keepWhileOff(o, authOption);

  o = section.option(
    form.Value,
    "torrserver_auth_password",
    _("TorrServer password"),
    _("The saved password is never shown on the page"),
  );
  o.depends("torrserver_auth_enabled", "1");
  notifications.configureSecret(
    o,
    "torrserver_auth_password",
    PASSWORD,
    _("Use up to 128 characters, without line breaks"),
    "",
    _("Delete the saved password"),
  );
  // On without a password TorrServer would not start: one is needed.
  const validateSecret = o.validate;
  o.validate = function (section_id, value) {
    const normalized = value ? `${value}`.trim() : "";
    if (!normalized && !savedPassword(section_id)) {
      return _("Enter a password");
    }
    return validateSecret.apply(this, arguments);
  };
  notifications.keepWhileOff(o, authOption);

  const jailAvailable = Boolean(capabilities?.ujailAvailable);
  o = section.option(
    form.Flag,
    "torrserver_jail",
    _("Run TorrServer in a jail"),
    jailAvailable
      ? _(
          "procd's jail (ujail): TorrServer sees only its program, its data, its disk cache and what it needs to resolve names and check certificates. A disk cache folder changed in TorrServer is seen after TorrServer restarts. If the jail cannot be set up, TorrServer does not start",
        )
      : _(
          "Not available: this firmware has no procd-ujail. Install the procd-ujail package to use it",
        ),
  );
  o.default = "0";
  o.rmempty = false;
  // Without ujail it can only be turned off (TorrServer would not start).
  if (!jailAvailable) {
    const load = o.load;
    o.load = function () {
      const value = load.apply(this, arguments);
      this.readonly = `${value || ""}` !== "1";
      return value;
    };
  }
}

return baseclass.extend({
  createTorrServerContent,
});
