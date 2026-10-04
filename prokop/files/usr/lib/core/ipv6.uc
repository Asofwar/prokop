// Whether this router runs IPv6 (A1). With net.ipv6.conf.all or .lo
// disable_ipv6=1, the IPv6 TPROXY route (local ::/0) and rule cannot be
// added, and sing-box cannot listen on ::1: a start that required them
// failed and was retried forever, without any proxy. Prokop then runs
// IPv4 only; no IPv6 traffic passes, so none leaks around the proxy. A
// kernel that has IPv6 and fails to set it up still fails the start.
let fs = require("fs");

const SYSCTL_DIR = getenv("PROKOP_IPV6_SYSCTL_DIR") || "/proc/sys/net/ipv6";

function disabled_on(name) {
    return trim("" + (fs.readfile(SYSCTL_DIR + "/conf/" + name + "/disable_ipv6") ?? "0")) == "1";
}

function available() {
    return !disabled_on("all") && !disabled_on("lo");
}

return { available };
