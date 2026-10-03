#!/usr/bin/env bash
# A configuration that the migrations of this release have nothing left to
# do on (config/migration.uc migrated): service/package.uc starts Prokop
# again after an upgrade only on one (UC-026).
#
# Source this file and call
#   migrated_settings_state <prokop lib> <scratch directory>
# It prints the lines of a UCI state file (core/uci.uc PROKOP_UCI_STATE_FILE)
# that record every migration of the release and the config_version its
# migrations write in prokop.settings; add them to the case's own. Both come
# from config/migration.uc, so a release that adds a migration or raises the
# version needs no change here.

migrated_settings_state() {
  local lib="$1" scratch="$2" state
  cat >"$scratch/migrated-settings.uc" <<'UC'
let migration = require("config.migration");
let ids = migration.migration_ids();
// The version the migrations write over an old one, on settings that
// record every migration, so that none of them runs.
let settings = { ".name": "settings", ".type": "settings", ".anonymous": false,
    config_version: "0", applied_migrations: [ ...ids ] };
if (length(ids) == 0 || migration.migrate_sections([ settings ], "") == null ||
    type(settings.config_version) != "string" || settings.config_version == "0")
    exit(1);
printf("prokop.settings.config_version=%s\nprokop.settings.applied_migrations=%s\n",
    settings.config_version, join(" ", ids));
UC
  state="$(ucode -L "$lib" "$scratch/migrated-settings.uc")" || return 1
  [ -n "$state" ] || return 1
  printf '%s\n' "$state"
}
