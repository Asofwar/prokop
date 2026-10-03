#!/usr/bin/env ucode

let lib = getenv("PROKOP_LIB") || "/usr/lib/prokop";
function quote(value) { return "'" + replace(value, /'/g, "'\\''") + "'"; }
exit(system("sh " + quote(lib + "/full-uninstall.sh") + " start"));
