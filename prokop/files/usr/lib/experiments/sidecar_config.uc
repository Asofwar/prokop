// Local providers, isolated from the donors' global init scripts and configs.
let c = require("experiments.common");
let common = require("core.common");
const DIR = getenv("PROKOP_SIDECAR_DIR") || "/var/run/prokop-sidecars";
function plan(sections) {
    let result = [], ports = {};
    for (let section in sections) {
        if (!common.bool_option(section, "enabled", false)) continue;
        let name = c.value(section[".name"]), kind = c.value(section.kind), raw = c.value(section.connection_secret);
        let port = c.value(section.port);
        if (match(name, /^[A-Za-z0-9_]{1,64}$/) == null || length(raw) > 65536) return c.fail("invalid_provider_config");
        if (match(port, /^[0-9]{4,5}$/) == null || int(port) < 1024 || int(port) > 65535 ||
            index([ 1602, 1603, 1604, 4534, 4590, 4591, 9090, 18054 ], int(port)) >= 0 || ports[port]) return c.fail("invalid_or_duplicate_provider_port");
        ports[port] = true;
        let config, binary, args;
        let path = DIR + "/" + name + ".config.json";
        if (kind == "xray") {
            let outbound;
            try { outbound = json(raw); } catch (e) { return c.fail("invalid_xray_outbound_json"); }
            if (type(outbound) != "object" || index([ "vless", "vmess", "trojan", "shadowsocks", "socks", "http" ], outbound.protocol) < 0)
                return c.fail("unsupported_xray_outbound");
            outbound.tag = "provider";
            if (type(outbound.streamSettings) != "object") outbound.streamSettings = {};
            if (type(outbound.streamSettings.sockopt) != "object") outbound.streamSettings.sockopt = {};
            // An unprivileged provider cannot use SO_MARK; its dedicated uid
            // is excluded from output capture instead.
            delete outbound.streamSettings.sockopt.mark;
            config = { log: { loglevel: "warning" },
                inbounds: [ { tag: "local", listen: "127.0.0.1", port: int(port), protocol: "socks", settings: { auth: "noauth", udp: true } } ],
                outbounds: [ outbound ] };
            binary = "/usr/bin/xray"; args = [ binary, "run", "-config", path ];
        }
        else if (kind == "wdtt") {
            let parsed = require("providers.wdtt.validator").parse_qwdtt_uri(raw);
            if (parsed == null || !parsed.valid || parsed.hashes == "") return c.fail("invalid_qwdtt_uri");
            config = { mode: "socks", socks: "127.0.0.1:" + port, peer: parsed.peer,
                password: parsed.pass, hashes: split(parsed.hashes, ","), workers: int(parsed.workers || 9),
                device_id: name, dns: "yandex", obfs: "audio", captcha_mode: "auto", vk_auth: "anonymous",
                captcha_token_file: DIR + "/" + name + "/captcha.token" };
            binary = "/usr/bin/qwdtt-client"; args = [ binary, "-config", path ];
        }
        else if (kind == "olcrtc") {
            let parsed = require("providers.olcrtc.validator").parse_uri(raw);
            if (parsed == null || !parsed.valid || parsed.crypto_key == "" || parsed.payload != "") return c.fail("invalid_or_unsupported_olcrtc_uri");
            // JSON is YAML 1.2, accepted by the upstream YAML config reader.
            config = { mode: "cnc", auth: { provider: parsed.provider }, room: { id: parsed.room_id },
                crypto: { key: parsed.crypto_key }, net: { transport: parsed.transport, dns: "1.1.1.1:53" },
                socks: { host: "127.0.0.1", port: int(port) }, data: DIR + "/" + name, debug: false };
            binary = "/usr/bin/olcrtc"; args = [ binary, path ];
        }
        else return c.fail("unsupported_provider");
        push(result, { name, kind, port: int(port), binary, args, config, path, data: DIR + "/" + name,
            url: "socks5://127.0.0.1:" + port });
    }
    return { success: true, providers: result };
}
function uid() {
    let passwd = require("fs").readfile("/etc/passwd");
    for (let line in split(c.value(passwd), "\n")) {
        let fields = split(line, ":");
        if (fields[0] == "prokop-sidecar" && match(fields[2], /^[0-9]+$/) != null && int(fields[2]) > 0) return fields[2];
    }
    return "";
}
return { plan, uid, DIR };
