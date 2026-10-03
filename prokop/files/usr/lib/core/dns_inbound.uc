// The one owner of the address of the sing-box DNS inbound: sing-box listens
// on it and dnsmasq forwards to it, so every module takes it from here and an
// SB_DNS_INBOUND_ADDRESS override moves both together (UC-183). A module of
// its own, without the UCI read of core/constants.uc, for the 1 Hz UI poll.

return {
    ADDRESS: getenv("SB_DNS_INBOUND_ADDRESS") || "127.0.0.42"
};
