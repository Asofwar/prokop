// Stand-in for autotune/apply.uc:
//   status          $STUB_APPLY_STATUS or a clean state;
//   plan <sel> <r>  $STUB_TUNE_DIR/plan.json or a ready plan for the
//                   selection, owned by $STUB_PLAN_OWNER (default youtube);
//   apply <plan> <r> $STUB_TUNE_DIR/apply.json or "applied" with started_at
//                   1700000000 (after $STUB_APPLY_SLEEP seconds, when set);
//   rollback [observation <id>]  $STUB_TUNE_DIR/rollback.json or a rolled
//                   back apply of candidate fake in group youtube;
//   observe <id>    $STUB_TUNE_DIR/observe.json or a passed check;
//   confirm <id>    $STUB_TUNE_DIR/confirm.json or a confirmed candidate.
// plan, apply (with " observed" for an observed one), rollback, observe and
// confirm calls are logged to
// $STUB_TUNE_DIR/apply.log.
let fs = require("fs");
let dir = getenv("STUB_TUNE_DIR");
let read_json = (path) => { let d = fs.readfile(path); try { return d == null ? null : json(d); } catch (e) { return null; } };
let log = (line) => { let f = fs.open(dir + "/apply.log", "a"); f.write(line + "\n"); f.close(); };
let mode = ARGV[0];
if (mode == "status") {
    let data = fs.readfile(getenv("STUB_APPLY_STATUS"));
    print(data != null ? data : sprintf("%J\n", { state: null, guards: [], snapshot_operation: false,
        service_action: null, autotune_lock_held: false }));
}
else if (mode == "plan") {
    let sel = read_json(ARGV[1]);
    log(sprintf("plan %s %s %s", sel ? sel.target.host : "-", sel ? sel.selected : "-", ARGV[2]));
    let data = fs.readfile(dir + "/plan.json");
    print(data != null ? data : sprintf("%J\n", { status: "ready", selected: sel.selected, target: sel.target,
        owner: { decided: true, kind: "zapret", section: getenv("STUB_PLAN_OWNER") || "youtube" } }));
}
else if (mode == "apply") {
    let plan = read_json(ARGV[1]);
    log(sprintf("apply %s %s %s%s", plan ? plan.owner.section : "-", plan ? plan.selected : "-", ARGV[2],
        ARGV[3] != null ? " " + ARGV[3] : ""));
    if (getenv("STUB_APPLY_SLEEP")) system("sleep " + getenv("STUB_APPLY_SLEEP"));
    let data = fs.readfile(dir + "/apply.json");
    print(data != null ? data : sprintf("%J\n", { status: "applied", reason: null, applied: true, started_at: 1700000000 }));
}
else if (mode == "observe") {
    log("observe " + ARGV[1]);
    let data = fs.readfile(dir + "/observe.json");
    print(data != null ? data : sprintf("%J\n", { status: "ok", reason: null, successes: 3, attempted: 3 }));
}
else if (mode == "confirm") {
    log("confirm " + ARGV[1]);
    let data = fs.readfile(dir + "/confirm.json");
    print(data != null ? data : sprintf("%J\n", { status: "confirmed", reason: null }));
}
else if (mode == "rollback") {
    log(ARGV[0] + (ARGV[1] != null ? " " + ARGV[1] + " " + ARGV[2] : ""));
    let data = fs.readfile(dir + "/rollback.json");
    print(data != null ? data : sprintf("%J\n", { status: "rolled_back", phase: "rolled_back", reason: "operator_rollback",
        selected: "fake", mutation: { section: "youtube", option: "nfqws_opt" }, rollback: { status: "success" }, applied: false }));
}
else exit(1);
