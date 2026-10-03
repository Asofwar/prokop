"use strict";
"require baseclass";
"require form";
"require uci";
"require ui";
"require view.prokop.main as main";

// The configuration forms of Prokop (Rules, Settings): a UCI form, the
// pages' Save & Apply that takes a snapshot first and, once the reload is
// confirmed, lists what changed since it; and the rules grid setup.

const UCI_PACKAGE = main.PROKOP_UCI_PACKAGE;

function renderSectionAdd(sectionRef, extra_class) {
  const el = form.GridSection.prototype.renderSectionAdd.apply(sectionRef, [
    extra_class,
  ]);
  const nameEl = el.querySelector(".cbi-section-create-name");

  ui.addValidator(
    nameEl,
    "uciname",
    true,
    (value) => {
      const button = el.querySelector(".cbi-section-create > .cbi-button-add");
      const uciconfig = sectionRef.uciconfig || sectionRef.map.config;

      if (!value) {
        button.disabled = true;
        return true;
      }

      if (uci.get(uciconfig, value)) {
        button.disabled = true;
        return _("Expecting: %s").format(_("unique UCI identifier"));
      }

      button.disabled = null;
      return true;
    },
    "blur",
    "keyup",
  );

  return el;
}

function getRuleEditButtonText() {
  const label = _("Edit rule action");

  return label === "Edit rule action" ? "Edit" : label;
}

function configureGridSection(sectionRef, type, title, addTitle) {
  sectionRef.anonymous = false;
  sectionRef.addremove = true;
  sectionRef.sortable = true;
  sectionRef.rowcolors = true;
  sectionRef.nodescriptions = true;
  sectionRef.modaltitle = function (section_id) {
    const label = uci.get(UCI_PACKAGE, section_id, "label");
    return section_id ? `${title}: ${label || section_id}` : addTitle;
  };
  sectionRef.sectiontitle = function (section_id) {
    return uci.get(UCI_PACKAGE, section_id, "label") || section_id;
  };
  sectionRef.renderSectionAdd = function (extra_class) {
    return renderSectionAdd(sectionRef, extra_class);
  };

  if (type === "section") {
    sectionRef.renderRowActions = function (section_id) {
      return form.TableSection.prototype.renderRowActions.call(
        this,
        section_id,
        getRuleEditButtonText(),
      );
    };
  }
}

// Why the pre-apply snapshot was refused (config/snapshots.uc create). Save &
// Apply never runs without it, so the refusal names its reason (UC-225).
function snapshotRefusalText(snapshot) {
  const data = snapshot.success ? snapshot.data : null;
  if (data?.status === "busy")
    return _(
      "Another snapshot operation is already in progress. Changes were not applied; try again in a moment.",
    );
  switch (data?.reason) {
    // Automatic snapshots keep reserved places (D-14); a store full of
    // protected snapshots is named with its remedy all the same.
    case "retention_full":
      return _(
        "Snapshot storage is full: delete a manual snapshot in History and recovery. Changes were not applied.",
      );
    case "lock_unavailable":
      return _(
        "Could not save a pre-apply configuration snapshot: the snapshot storage could not be locked. Changes were not applied; try again in a moment.",
      );
    case "config_unavailable":
      return _(
        "Could not save a pre-apply configuration snapshot: the configuration file could not be read. Changes were not applied.",
      );
    case "hash_unavailable":
    case "write_failed":
      return _(
        "Could not save a pre-apply configuration snapshot: it could not be written. Check the free space on the router. Changes were not applied.",
      );
    default:
      return _(
        "Could not save a pre-apply configuration snapshot. Changes were not applied.",
      );
  }
}

// Save & Apply is the footer button of the page's view: luci.js binds it to
// view.handleSaveApply, which saves every map of the page (handleSave) and
// then starts ui.changes.apply(); form.Map has no such method (UC-064,
// UC-224). The Rules and Settings views take handleSaveApply below in its
// place: a snapshot of the configuration as it is before the apply comes
// first. Without it the changes are saved, as Save does, but not applied,
// and the page says why. The Unsaved Changes dialog in LuCI's header
// applies without any view, so without this snapshot (a known limitation).
//
// LuCI reloads the page once it has confirmed the apply (ui.changes.confirm
// dispatches "uci-applied", then sets window.location), before the Prokop
// reload that the commit starts has finished. What the report of that
// reload needs is kept in sessionStorage when LuCI confirms the apply; the
// page that loads then reports it (reportPendingApply).
const PENDING_APPLY_KEY = "prokop-pending-apply";
// The reload has this long from LuCI's confirmation of the apply; a record
// older than the second limit (no form page loaded since) is dropped.
const APPLY_REPORT_WAIT_MS = 90 * 1000;
const APPLY_RECORD_MAX_AGE_MS = 10 * 60 * 1000;
const APPLY_POLL_INTERVAL_MS = 2000;
// LuCI confirms an apply before its rollback timeout (L.env.apply_rollback,
// 90 s unless set) has passed since the request; this much more is left for
// the request itself. An apply that LuCI never confirmed (nothing to apply,
// refused, rolled back) is not reported when a later one is confirmed.
const APPLY_CONFIRM_MARGIN_MS = 30 * 1000;

// The snapshot and the last reload before the apply that this page started.
let pendingApply = null;

function sessionStore() {
  try {
    return window.sessionStorage || null;
  } catch (e) {
    return null;
  }
}

function markReloading() {
  if (main.store && typeof main.store.set === "function") {
    const servicesInfoWidget = main.store.get().servicesInfoWidget;
    main.store.set({
      servicesInfoWidget: {
        ...servicesInfoWidget,
        data: {
          ...servicesInfoWidget.data,
          prokopStatus: "reloading",
        },
      },
    });
  }
}

if (
  typeof document !== "undefined" &&
  typeof document.addEventListener === "function"
) {
  document.addEventListener("uci-applied", () => {
    const apply = pendingApply;
    pendingApply = null;
    const rollback = (Number(L.env?.apply_rollback) || 90) * 1000;
    if (
      !apply ||
      Date.now() - apply.startedAt > rollback + APPLY_CONFIRM_MARGIN_MS
    )
      return;
    const record = {
      snapshot: apply.snapshot,
      reloadAt: apply.reloadAt,
      confirmedAt: Date.now(),
    };
    try {
      sessionStore()?.setItem(PENDING_APPLY_KEY, JSON.stringify(record));
    } catch (e) {
      // Without the record the next page reports nothing.
    }
    markReloading();
  });
}

// The previous release of the backend (the packages upgraded one at a time)
// takes only manual and automatic snapshots and refuses before-apply without
// a reason: the same snapshot is then taken as automatic.
async function snapshotBeforeApply() {
  const snapshot = await main.ProkopShellMethods.snapshotCreate("before-apply");
  if (
    snapshot.success &&
    snapshot.data?.status === "failed" &&
    !snapshot.data.reason
  )
    return main.ProkopShellMethods.snapshotCreate("automatic");
  return snapshot;
}

async function handleSaveApply(ev, mode) {
  pendingApply = null;
  const snapshot = await snapshotBeforeApply();
  if (
    !snapshot.success ||
    !["created", "existing"].includes(snapshot.data?.status)
  ) {
    await this.handleSave(ev);
    ui.addNotification(
      null,
      E("div", {}, [
        E("p", {}, [snapshotRefusalText(snapshot)]),
        E("p", {}, [
          _(
            "The changes are saved: Save & Apply applies them once a snapshot can be taken.",
          ),
        ]),
      ]),
      "error",
    );
    return;
  }
  // A reload recorded after this one is the reload of this apply. Unknown,
  // or while a reload runs (an earlier apply's, a list update's: it ends
  // with an event that may come before or after this apply's), the reload
  // of this apply cannot be told from another one.
  const health = await main.ProkopShellMethods.getHealthStatus();
  const reloadAt =
    health.success && health.data?.reload?.busy !== true
      ? Number(health.data?.last_reload?.timestamp) || 0
      : null;
  // luci.js view.handleSaveApply (24.10, 25.12), with a look at what the
  // apply commits in between: only changes of Prokop reload it, and only
  // that reload is reported.
  await this.handleSave(ev);
  const staged = await Promise.resolve(uci.changes?.()).catch(() => null);
  if (staged == null || staged[UCI_PACKAGE]?.length)
    pendingApply = {
      snapshot: snapshot.data.snapshot.id,
      reloadAt,
      startedAt: Date.now(),
    };
  ui.changes.apply(mode == "0");
}

function takePendingApply() {
  const store = sessionStore();
  let record = null;
  try {
    record = JSON.parse(store?.getItem(PENDING_APPLY_KEY) || "null");
    store?.removeItem(PENDING_APPLY_KEY);
  } catch (e) {
    return null;
  }
  const age = Date.now() - Number(record?.confirmedAt);
  return record &&
    typeof record.snapshot === "string" &&
    age >= 0 &&
    age < APPLY_RECORD_MAX_AGE_MS
    ? record
    : null;
}

// The Prokop reload of the apply LuCI confirmed before it loaded this page:
// a reload event newer than the last one before the apply (health record),
// once no reload runs: the one that ran when this page loaded may have been
// another one, with this apply's queued behind it. None comes while Prokop
// is stopped or not started since boot (D-15).
function waitForApplyReload(record) {
  const deadline = record.confirmedAt + APPLY_REPORT_WAIT_MS;
  const poll = () =>
    main.ProkopShellMethods.getHealthStatus().then((health) => {
      const data = health.success ? health.data : null;
      const reload = data?.last_reload;
      if (
        record.reloadAt != null &&
        reload?.kind === "reload" &&
        Number(reload.timestamp) > record.reloadAt &&
        data?.reload?.busy !== true
      )
        return { reload };
      if (["stopped", "not_started"].includes(data?.service?.prokop))
        return { stopped: true };
      if (record.reloadAt == null || Date.now() >= deadline) return {};
      return new Promise((resolve) =>
        window.setTimeout(resolve, APPLY_POLL_INTERVAL_MS),
      ).then(poll);
    });
  return poll();
}

// Confirmed: what changed since the pre-apply snapshot.
async function applyOutcomeText(record, outcome) {
  if (outcome.stopped)
    return _(
      "Configuration saved. Prokop is not running: the changes take effect when it is started.",
    );
  if (!outcome.reload)
    return _(
      "Configuration saved. Runtime reload has not been confirmed; check History and recovery.",
    );
  if (outcome.reload.status !== "success")
    return _(
      "Configuration saved. Runtime reload failed; check History and recovery.",
    );
  const diff = await main.ProkopShellMethods.snapshotDiff(record.snapshot);
  if (!diff.success || !Array.isArray(diff.data))
    return [
      _("Configuration applied successfully"),
      _("The list of changes is unavailable."),
    ].join("\n");
  const entries = diff.data;
  // UC-062: a diff longer than the backend lists ends with
  // { truncated, total } in place of the rest.
  const changes = entries.filter((entry) => entry.truncated !== true);
  const marker = entries.find((entry) => entry.truncated === true);
  const more = marker
    ? Math.max((Number(marker.total) || 0) - changes.length, 0)
    : 0;
  // null: the option is not set on that side (D-2).
  const diffValue = (value) =>
    value === null || value === undefined
      ? _("not set")
      : Array.isArray(value)
        ? JSON.stringify(value)
        : value;
  return [
    _("Configuration applied successfully"),
    ...changes.map(
      (change) =>
        `${change.section}.${change.option}: ${diffValue(change.before)} → ${diffValue(change.after)}`,
    ),
    ...(more ? [_("and %d more").format(more)] : []),
  ].join("\n");
}

function reportPendingApply() {
  const record = takePendingApply();
  if (!record) return Promise.resolve(null);
  return waitForApplyReload(record)
    .then((outcome) =>
      applyOutcomeText(record, outcome).then((text) => {
        const confirmed = outcome.reload?.status === "success";
        ui.addNotification(
          null,
          E("p", { style: "white-space: pre-line" }, [text]),
          confirmed ? "info" : "warning",
        );
        return outcome;
      }),
    )
    .catch(() => null);
}

function createMap(title, description) {
  // A page that LuCI loaded after an apply reports that apply.
  reportPendingApply();
  return new form.Map(UCI_PACKAGE, title, description);
}

const EntryPoint = {
  createMap,
  configureGridSection,
  handleSaveApply,
};

return baseclass.extend(EntryPoint);
