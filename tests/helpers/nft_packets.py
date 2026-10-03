#!/usr/bin/env python3
"""Real packets through the router's nft hooks, for tests in a private
network namespace (tests/nft_dataplane_real.sh).

  setup IFNAME ADDR4/PREFIX
      creates a persistent TUN interface standing in for the LAN bridge with
      the router's address, brings it and lo up and routes everything else
      out of it (the router's default route)
  lan IFNAME SRC DST tcp|udp DPORT
      a LAN client SRC sends one packet (a TCP SYN or a UDP datagram) to
      DST:DPORT; it enters the router through IFNAME (prerouting)
  local DST tcp|udp DPORT [MARK]
      a process on the router sends one packet to DST:DPORT from a socket
      with that SO_MARK (0 by default, like ciadpi's upstream sockets)

Where the packets go afterwards does not matter: the test reads what the
hooks did to them.
"""

import errno
import fcntl
import os
import socket
import struct
import sys

TUNSETIFF = 0x400454CA
TUNSETPERSIST = 0x400454CB
IFF_TUN = 0x0001
IFF_NO_PI = 0x1000
SIOCSIFADDR = 0x8916
SIOCSIFNETMASK = 0x891C
SIOCGIFFLAGS = 0x8913
SIOCSIFFLAGS = 0x8914
SIOCADDRT = 0x890B
IFF_UP = 0x1
RTF_UP = 0x1
SO_MARK = 36


def open_tun(name, persist=False):
    fd = os.open("/dev/net/tun", os.O_RDWR)
    fcntl.ioctl(fd, TUNSETIFF, struct.pack("16sH", name.encode(), IFF_TUN | IFF_NO_PI))
    if persist:
        fcntl.ioctl(fd, TUNSETPERSIST, 1)
    return fd


def interface_up(sock, name):
    flags = struct.unpack("16sH", fcntl.ioctl(sock, SIOCGIFFLAGS, struct.pack("16sH", name.encode(), 0)))[1]
    fcntl.ioctl(sock, SIOCSIFFLAGS, struct.pack("16sH", name.encode(), flags | IFF_UP))


def sockaddr_in(ip):
    return struct.pack("HH4s8x", socket.AF_INET, 0, socket.inet_aton(ip))


def setup(name, addr4):
    os.close(open_tun(name, persist=True))
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    address, prefix = addr4.split("/")
    mask = socket.inet_ntoa(struct.pack("!I", (0xFFFFFFFF << (32 - int(prefix))) & 0xFFFFFFFF))

    def ifaddr(ip):
        return struct.pack("16sH2s4s8s", name.encode(), socket.AF_INET, b"\0\0", socket.inet_aton(ip), b"\0" * 8)

    fcntl.ioctl(sock, SIOCSIFADDR, ifaddr(address))
    fcntl.ioctl(sock, SIOCSIFNETMASK, ifaddr(mask))
    interface_up(sock, name)
    interface_up(sock, "lo")
    # struct rtentry: the default route out of the TUN interface.
    import ctypes

    dev = ctypes.create_string_buffer(name.encode())
    route = struct.pack(
        "L16s16s16sHhLPhxxxxxxPLLH6x",
        0, sockaddr_in("0.0.0.0"), sockaddr_in("0.0.0.0"), sockaddr_in("0.0.0.0"),
        RTF_UP, 0, 0, 0, 0, ctypes.addressof(dev), 0, 0, 0,
    )
    fcntl.ioctl(sock, SIOCADDRT, route)


def checksum(data):
    if len(data) % 2:
        data += b"\0"
    total = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return ~total & 0xFFFF


def ipv4_packet(src, dst, proto, dport):
    sport = 40000 + (dport % 20000)
    if proto == "udp":
        number = socket.IPPROTO_UDP
        payload = b"forkop"
        l4 = struct.pack("!HHHH", sport, dport, 8 + len(payload), 0) + payload
    else:
        number = socket.IPPROTO_TCP
        l4 = struct.pack("!HHIIBBHHH", sport, dport, 1, 0, 5 << 4, 0x02, 65535, 0, 0)
    pseudo = socket.inet_aton(src) + socket.inet_aton(dst) + struct.pack("!BBH", 0, number, len(l4))
    csum = checksum(pseudo + l4)
    if proto == "udp":
        l4 = l4[:6] + struct.pack("!H", csum or 0xFFFF) + l4[8:]
    else:
        l4 = l4[:16] + struct.pack("!H", csum) + l4[18:]
    header = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(l4), 1, 0, 64, number, 0,
                         socket.inet_aton(src), socket.inet_aton(dst))
    header = header[:10] + struct.pack("!H", checksum(header)) + header[12:]
    return header + l4


def lan(name, src, dst, proto, dport):
    fd = open_tun(name)
    try:
        os.write(fd, ipv4_packet(src, dst, proto, int(dport)))
    finally:
        os.close(fd)


def local(dst, proto, dport, mark="0"):
    kind = socket.SOCK_DGRAM if proto == "udp" else socket.SOCK_STREAM
    sock = socket.socket(socket.AF_INET, kind)
    mark = int(mark, 0)
    if mark:
        sock.setsockopt(socket.SOL_SOCKET, SO_MARK, mark)
    if proto == "udp":
        sock.sendto(b"forkop", (dst, int(dport)))
    else:
        sock.setblocking(False)
        result = sock.connect_ex((dst, int(dport)))
        if result not in (0, errno.EINPROGRESS):
            raise OSError(result, os.strerror(result))
    sock.close()


def main(argv):
    commands = {"setup": setup, "lan": lan, "local": local}
    if len(argv) < 2 or argv[1] not in commands:
        sys.stderr.write(__doc__)
        return 2
    commands[argv[1]](*argv[2:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
