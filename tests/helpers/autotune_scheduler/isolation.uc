// Stand-in for autotune/isolation.uc tune: the result of a host comes from
// $STUB_TUNE_DIR/<host>.json (default: inconclusive); every call is logged.
let fs = require("fs");
let dir = getenv("STUB_TUNE_DIR");
let host = ARGV[1];
let log = fs.open(dir + "/calls.log", "a");
log.write(sprintf("%s %s %s\n", ARGV[0], host, join(" ", slice(ARGV, 2))));
log.close();
// The phase report the manager asks for (autotune/isolation.uc progress).
if (getenv("PROKOP_AUTOTUNE_PROGRESS")) fs.writefile(getenv("PROKOP_AUTOTUNE_PROGRESS"), sprintf("%J
", { phase: "measuring", done: 3, total: 8 }));
if (getenv("STUB_TUNE_SLEEP")) system("sleep " + getenv("STUB_TUNE_SLEEP"));
let hook = fs.readfile(dir + "/" + host + ".hook");
if (hook != null) { fs.unlink(dir + "/" + host + ".hook"); system(hook); }
let data = fs.readfile(dir + "/" + host + ".json");
print(data != null ? data : sprintf("%J\n", { status: "inconclusive", reason: "all_failed", target: { host }, candidates: [] }));
