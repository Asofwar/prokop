#!/usr/bin/env python3
"""Client DNS through a router's firewall, for tests in a private network
namespace (tests/killswitch_dns_exempt_nft_real.sh).

  setup IFNAME ADDR4/PREFIX ADDR6/PREFIX
      creates a persistent TUN interface standing in for the LAN bridge,
      with the router's addresses, and brings it and lo up
  serve MAIN_SERVERS_FILE CONF...
      answers DNS like the router's resolvers: the main dnsmasq on port 53
      with the block list it reads (MAIN_SERVERS_FILE, read at every query),
      and one dnsmasq per CONF on the port the configuration names, with its
      server= and address= lines, listening where such a dnsmasq listens
      (its interface= lines). A name a resolver does not block is answered
      with 203.0.113.N, N standing for the resolver (53 for the main one,
      PORT - 18000 for the others); a blocked one with NXDOMAIN
  query IFNAME SRC DST NAME [PORT]
      sends an A query for NAME from client SRC to DST (port 53 by default)
      into the LAN interface and prints what comes back to the client:
      "rcode=R answer=A sport=P" or "noreply"
  dig [+short] [+time=N] [+tries=N] [-p PORT] @SERVER NAME [A]
      what the kill-switch watcher runs: a query to SERVER, +short output
"""

import fcntl
import os
import random
import select
import socket
import struct
import sys
import threading
import time

TUNSETIFF = 0x400454CA
TUNSETPERSIST = 0x400454CB
IFF_TUN = 0x0001
IFF_NO_PI = 0x1000
SIOCGIFADDR = 0x8915
SIOCSIFADDR = 0x8916
SIOCSIFNETMASK = 0x891C
SIOCGIFFLAGS = 0x8913
SIOCSIFFLAGS = 0x8914
IFF_UP = 0x1


def open_tun(name, persist=False):
    fd = os.open("/dev/net/tun", os.O_RDWR)
    fcntl.ioctl(fd, TUNSETIFF, struct.pack("16sH", name.encode(), IFF_TUN | IFF_NO_PI))
    if persist:
        fcntl.ioctl(fd, TUNSETPERSIST, 1)
    return fd


def interface_up(sock, name):
    flags = struct.unpack("16sH", fcntl.ioctl(sock, SIOCGIFFLAGS, struct.pack("16sH", name.encode(), 0)))[1]
    fcntl.ioctl(sock, SIOCSIFFLAGS, struct.pack("16sH", name.encode(), flags | IFF_UP))


def setup(name, addr4, addr6):
    fd = open_tun(name, persist=True)
    os.close(fd)
    ipv6 = os.path.isdir(f"/proc/sys/net/ipv6/conf/{name}")
    if ipv6:
        with open(f"/proc/sys/net/ipv6/conf/{name}/accept_dad", "w") as handle:
            handle.write("0\n")
        with open(f"/proc/sys/net/ipv6/conf/{name}/disable_ipv6", "w") as handle:
            handle.write("0\n")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    address, prefix = addr4.split("/")
    mask = socket.inet_ntoa(struct.pack("!I", (0xFFFFFFFF << (32 - int(prefix))) & 0xFFFFFFFF))

    def sockaddr(ip):
        return struct.pack("16sH2s4s8s", name.encode(), socket.AF_INET, b"\0\0", socket.inet_aton(ip), b"\0" * 8)

    fcntl.ioctl(sock, SIOCSIFADDR, sockaddr(address))
    fcntl.ioctl(sock, SIOCSIFNETMASK, sockaddr(mask))
    interface_up(sock, name)
    interface_up(sock, "lo")
    if not ipv6:
        print("ipv6 unavailable")
        return
    sock6 = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    address6, prefix6 = addr6.split("/")
    request = struct.pack("16sIi", socket.inet_pton(socket.AF_INET6, address6), int(prefix6), socket.if_nametoindex(name))
    fcntl.ioctl(sock6, SIOCSIFADDR, request)
    print("ipv6 available")


# ---- DNS messages ---------------------------------------------------------------


def encode_name(name):
    return b"".join(bytes([len(label)]) + label.encode() for label in name.strip(".").split(".")) + b"\0"


def decode_name(data, offset):
    labels = []
    while True:
        length = data[offset]
        if length & 0xC0:
            pointer = struct.unpack("!H", data[offset:offset + 2])[0] & 0x3FFF
            labels.append(decode_name(data, pointer)[0])
            return ".".join(label for label in labels if label), offset + 2
        offset += 1
        if length == 0:
            return ".".join(labels), offset
        labels.append(data[offset:offset + length].decode())
        offset += length


def build_query(name, ident):
    return struct.pack("!HHHHHH", ident, 0x0100, 1, 0, 0, 0) + encode_name(name) + struct.pack("!HH", 1, 1)


def parse_query(data):
    ident, _flags, _qd, _an, _ns, _ar = struct.unpack("!HHHHHH", data[:12])
    name, offset = decode_name(data, 12)
    return ident, name.lower(), data[12:offset + 4]


def build_response(ident, question, rcode, address):
    answers = 1 if address else 0
    header = struct.pack("!HHHHHH", ident, 0x8180 | rcode, 1, answers, 0, 0)
    body = question
    if address:
        body += struct.pack("!HHHIH", 0xC00C, 1, 1, 30, 4) + socket.inet_aton(address)
    return header + body


def parse_response(data):
    _ident, flags, qdcount, ancount, _ns, _ar = struct.unpack("!HHHHHH", data[:12])
    offset = 12
    for _ in range(qdcount):
        offset = decode_name(data, offset)[1] + 4
    answers = []
    for _ in range(ancount):
        offset = decode_name(data, offset)[1]
        rtype, _rclass, _ttl, length = struct.unpack("!HHIH", data[offset:offset + 10])
        offset += 10
        if rtype == 1 and length == 4:
            answers.append(socket.inet_ntoa(data[offset:offset + 4]))
        offset += length
    return flags & 0xF, answers


# ---- resolvers ------------------------------------------------------------------


def read_rules(path):
    """server=/d/ blocks, server=/d/# and server=/d/IP resolve, address=/d/IP answers."""
    rules = {}
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return rules
    for line in lines:
        if line.startswith("server=/") or line.startswith("address=/"):
            kind, rest = line.split("=", 1)
            parts = rest.split("/")
            if len(parts) < 3:
                continue
            domain, target = parts[1].lower(), parts[2]
            if kind == "address":
                rules[domain] = ("address", target)
            elif target == "":
                rules[domain] = ("block", None)
            else:
                rules[domain] = ("resolve", None)
    return rules


def answer(rules, name, own_address):
    labels = name.split(".")
    for index in range(len(labels)):
        rule = rules.get(".".join(labels[index:]))
        if rule is None:
            continue
        if rule[0] == "block":
            return 3, None
        if rule[0] == "address":
            return 0, rule[1]
        return 0, own_address
    return 0, own_address


def listen_addresses(names):
    """Where a dnsmasq with --bind-dynamic and these --interface names
    listens: every address without a name; otherwise the addresses of the
    interfaces they match (a trailing * is a wildcard) and of loopback,
    which dnsmasq adds itself whenever an interface is named."""
    if not names:
        return None

    def wanted(ifname):
        return any(ifname.startswith(name[:-1]) if name.endswith("*") else ifname == name for name in names + ["lo"])

    addresses = []
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for _index, ifname in socket.if_nameindex():
        if not wanted(ifname):
            continue
        try:
            packed = fcntl.ioctl(sock, SIOCGIFADDR, struct.pack("256s", ifname.encode()[:15]))
            addresses.append(socket.inet_ntoa(packed[20:24]))
        except OSError:
            pass
    try:
        lines = open("/proc/net/if_inet6", encoding="utf-8").read().splitlines()
    except OSError:
        lines = []
    for line in lines:
        fields = line.split()
        # Global and host scope only; link-local needs a scope id.
        if len(fields) == 6 and wanted(fields[5]) and int(fields[3], 16) in (0x00, 0x10):
            addresses.append(socket.inet_ntop(socket.AF_INET6, bytes.fromhex(fields[0])))
    return addresses


def resolver(port, rules_path, interfaces=None):
    own = f"203.0.113.{port - 18000 if port >= 18000 else port}"
    addresses = listen_addresses(interfaces)
    socks = []
    if addresses is None and socket.has_ipv6 and os.path.isdir("/proc/sys/net/ipv6"):
        sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        sock.bind(("::", port))
        socks.append(sock)
    elif addresses is None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(("0.0.0.0", port))
        socks.append(sock)
    for address in addresses or []:
        sock = socket.socket(socket.AF_INET6 if ":" in address else socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind((address, port))
        socks.append(sock)
    while True:
        ready, _, _ = select.select(socks, [], [])
        for sock in ready:
            data, peer = sock.recvfrom(4096)
            try:
                ident, name, question = parse_query(data)
            except (IndexError, struct.error, UnicodeDecodeError):
                continue
            rcode, address = answer(read_rules(rules_path), name, own)
            with open(os.environ["DNS_TUN_LOG"], "a", encoding="utf-8") as log:
                log.write(f"{port} {peer[0]} {name} rcode={rcode}\n")
            sock.sendto(build_response(ident, question, rcode, address), peer)


def serve(main_servers, confs):
    threads = [threading.Thread(target=resolver, args=(53, main_servers), daemon=True)]
    for conf in confs:
        lines = open(conf, encoding="utf-8").read().splitlines()
        port = next(int(line[5:]) for line in lines if line.startswith("port="))
        interfaces = [line[10:] for line in lines if line.startswith("interface=")]
        threads.append(threading.Thread(target=resolver, args=(port, conf, interfaces), daemon=True))
    for thread in threads:
        thread.start()
    print("ready", flush=True)
    while True:
        time.sleep(3600)


# ---- a client behind the LAN interface --------------------------------------------


def checksum(data):
    if len(data) % 2:
        data += b"\0"
    total = sum(struct.unpack(f"!{len(data) // 2}H", data))
    total = (total >> 16) + (total & 0xFFFF)
    total += total >> 16
    return ~total & 0xFFFF


def udp_packet(src, dst, sport, dport, payload):
    length = 8 + len(payload)
    if ":" in src:
        pseudo = socket.inet_pton(socket.AF_INET6, src) + socket.inet_pton(socket.AF_INET6, dst) + struct.pack("!IxxxB", length, 17)
    else:
        pseudo = socket.inet_aton(src) + socket.inet_aton(dst) + struct.pack("!BBH", 0, 17, length)
    header = struct.pack("!HHHH", sport, dport, length, 0)
    header = struct.pack("!HHHH", sport, dport, length, checksum(pseudo + header + payload) or 0xFFFF)
    if ":" in src:
        ip = struct.pack("!IHBB", 0x60000000, length, 17, 64) + socket.inet_pton(socket.AF_INET6, src) + socket.inet_pton(socket.AF_INET6, dst)
    else:
        ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + length, 1, 0, 64, 17, 0, socket.inet_aton(src), socket.inet_aton(dst))
        ip = ip[:10] + struct.pack("!H", checksum(ip)) + ip[12:]
    return ip + header + payload


def reply_to(packet, client, sport):
    """The DNS payload and source port of a UDP packet to client:sport, or None."""
    if packet[0] >> 4 == 6:
        if packet[6] != 17 or socket.inet_ntop(socket.AF_INET6, packet[24:40]) != client:
            return None
        udp = packet[40:]
    else:
        if packet[9] != 17 or socket.inet_ntoa(packet[16:20]) != client:
            return None
        udp = packet[(packet[0] & 0xF) * 4:]
    source, destination = struct.unpack("!HH", udp[:4])
    return (udp[8:], source) if destination == sport else None


def query(name, src, dst, qname, dport=53):
    fd = open_tun(name)
    sport = random.randint(20000, 60000)
    ident = random.randint(0, 0xFFFF)
    packet = udp_packet(src, dst, sport, dport, build_query(qname, ident))
    os.write(fd, packet)
    # A reply normally comes within milliseconds; a test that expects one
    # waits longer (DNS_TUN_DEADLINE) so a loaded host does not read as
    # "noreply", while a test that expects silence keeps the short wait.
    # Like a real client, the query is sent again every second: on a loaded
    # host a reply can be lost although the resolver answered.
    start = time.time()
    deadline = start + float(os.environ.get("DNS_TUN_DEADLINE", "2"))
    resend = start + 1
    sent = 1
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], max(0, min(deadline, resend) - time.time()))
        if not ready:
            if time.time() >= resend and time.time() < deadline:
                os.write(fd, packet)
                sent += 1
                resend = time.time() + 1
            continue
        found = reply_to(os.read(fd, 65535), src, sport)
        if found:
            rcode, answers = parse_response(found[0])
            print(f"rcode={rcode} answer={','.join(answers)} sport={found[1]}")
            return 0
    print(f"dns_tun: no reply from {dst}:{dport} for {qname} after {sent} queries in {time.time() - start:.1f}s", file=sys.stderr)
    print("noreply")
    return 0


def dig(args):
    port, server, name, short = 53, None, None, False
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "-p":
            port = int(args[index + 1])
            index += 1
        elif arg == "+short":
            short = True
        elif arg.startswith("@"):
            server = arg[1:]
        elif not arg.startswith("+") and arg != "A":
            name = arg
        index += 1
    sock = socket.socket(socket.AF_INET6 if ":" in server else socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(1)
    ident = random.randint(0, 0xFFFF)
    try:
        sock.sendto(build_query(name, ident), (server, port))
        data = sock.recv(4096)
    except OSError:
        return 9
    rcode, answers = parse_response(data)
    print("\n".join(answers) if short else f"status: {rcode}")
    return 0


def main(argv):
    command = argv[1]
    if command == "setup":
        setup(argv[2], argv[3], argv[4])
    elif command == "serve":
        serve(argv[2], argv[3:])
    elif command == "query":
        return query(argv[2], argv[3], argv[4], argv[5], int(argv[6]) if len(argv) > 6 else 53)
    elif command == "dig":
        return dig(argv[2:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
