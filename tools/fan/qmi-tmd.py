#!/usr/bin/env python3
"""talk to the qualcomm qmi thermal mitigation device (tmd) service over af_qipcrtr.

this is how qualcomm's thermal-engine drives firmware side mitigation, and on
this laptop it is the closest thing to fan control that exists. it does not
expose a fan (see docs/fan-control.md). useful as a template for any qmi
service on the adsp or cdsp.

  qmi-tmd.py                    list mitigation devices on every tmd instance
  qmi-tmd.py --get DEV          read the current level
  qmi-tmd.py --set DEV LEVEL    write a level (this throttles hardware)

wire format notes that cost time:
  bind() needs the local node id from getsockname() first, node 0 is einval
  qmi header is u8 type, u16 txn, u16 msg_id, u16 len, then tlvs
  the device list tlv is u8 count, then per device u8 name_len, name, u8 max_level,
  not the fixed 32 byte struct the headers imply
"""
import ctypes
import ctypes.util
import socket
import struct
import subprocess
import sys

AF_QIPCRTR = 42
TMD_SERVICE = 24
TMD_GET_LIST, TMD_SET_LEVEL, TMD_GET_LEVEL = 0x0020, 0x0021, 0x0022
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)


class SockaddrQrtr(ctypes.Structure):
    _fields_ = [("family", ctypes.c_ushort), ("node", ctypes.c_uint), ("port", ctypes.c_uint)]


def open_sock(timeout=3):
    fd = libc.socket(AF_QIPCRTR, socket.SOCK_DGRAM, 0)
    if fd < 0:
        raise OSError(ctypes.get_errno(), "socket")
    me = SockaddrQrtr()
    ln = ctypes.c_int(12)
    if libc.getsockname(fd, ctypes.byref(me), ctypes.byref(ln)) < 0:
        raise OSError(ctypes.get_errno(), "getsockname")
    me.port = 0
    if libc.bind(fd, ctypes.byref(me), 12) < 0:
        raise OSError(ctypes.get_errno(), "bind")
    libc.setsockopt(fd, socket.SOL_SOCKET, socket.SO_RCVTIMEO, struct.pack("qq", timeout, 0), 16)
    return fd


def txn(fd, node, port, msg_id, payload=b""):
    dst = SockaddrQrtr(AF_QIPCRTR, node, port)
    m = struct.pack("<BHHH", 0, 1, msg_id, len(payload)) + payload
    if libc.sendto(fd, m, len(m), 0, ctypes.byref(dst), 12) < 0:
        return None
    buf = ctypes.create_string_buffer(8192)
    frm = SockaddrQrtr()
    fl = ctypes.c_int(12)
    r = libc.recvfrom(fd, buf, 8192, 0, ctypes.byref(frm), ctypes.byref(fl))
    if r < 0:
        return None
    d = buf.raw[:r]
    _, _, _, ln = struct.unpack_from("<BHHH", d, 0)
    tlvs, i = {}, 7
    while i + 3 <= 7 + ln:
        t = d[i]
        l = struct.unpack_from("<H", d, i + 1)[0]
        tlvs[t] = d[i + 3:i + 3 + l]
        i += 3 + l
    return tlvs


def instances():
    """tmd instances from qrtr-lookup, the fallback matches this machine"""
    out = []
    try:
        for line in subprocess.run(["qrtr-lookup"], capture_output=True, text=True,
                                   timeout=15).stdout.splitlines():
            f = line.split()
            if len(f) >= 5 and f[0] == str(TMD_SERVICE):
                out.append((int(f[3]), int(f[4])))
    except Exception:
        pass
    return out or [(5, 8), (10, 8)]


def devlist(fd, node, port):
    t = txn(fd, node, port, TMD_GET_LIST)
    if not t or 0x10 not in t:
        return []
    v = t[0x10]
    n, off, devs = v[0], 1, []
    for _ in range(n):
        if off >= len(v):
            break
        ln = v[off]
        name = v[off + 1:off + 1 + ln].decode(errors="replace")
        devs.append((name, v[off + 1 + ln]))
        off += 2 + ln
    return devs


def name_tlv(name):
    return bytes([0x01, len(name) + 1, 0, len(name)]) + name.encode()


def main():
    a = sys.argv[1:]
    fd = open_sock()
    if not a:
        for node, port in instances():
            print(f"tmd node {node} port {port}:")
            d = devlist(fd, node, port)
            if not d:
                print("  (no reply)")
                continue
            for name, mx in d:
                lv = txn(fd, node, port, TMD_GET_LEVEL, name_tlv(name))
                cur = lv[0x10][0] if lv and 0x10 in lv and lv[0x10] else "?"
                print(f"  {name:<26} level={cur}/{mx}")
        print("\nno fan device here, see docs/fan-control.md")
    elif a[0] == "--get" and len(a) == 2:
        for node, port in instances():
            r = txn(fd, node, port, TMD_GET_LEVEL, name_tlv(a[1]))
            if r and 0x10 in r:
                print(f"  node {node}: {a[1]} = {r[0x10][0]}")
    elif a[0] == "--set" and len(a) == 3:
        name, lvl = a[1], int(a[2])
        print(f"writing mitigation level {lvl} to {name}, this throttles hardware")
        p = name_tlv(name) + bytes([0x02, 1, 0, lvl])
        for node, port in instances():
            r = txn(fd, node, port, TMD_SET_LEVEL, p)
            if r and 0x02 in r:
                res, err = struct.unpack("<HH", r[0x02][:4])
                print(f"  node {node}: result={res} error={err}")
    else:
        print(__doc__)
    libc.close(fd)


if __name__ == "__main__":
    main()
