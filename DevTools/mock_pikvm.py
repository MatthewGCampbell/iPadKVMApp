#!/usr/bin/env python3
"""A tiny stand-in for PiKVM's kvmd-vnc, for testing the app's RFB core on a dev box.

It follows the same wire protocol as kvmd/apps/vnc/rfb: RFB 3.8, VeNCrypt with the
Plain subtype (no TLS here), Tight-JPEG framebuffer updates, QEMU extended key events,
and ClientCutText. Every message the client sends is logged as one JSON line on stdout.

    python3 mock_pikvm.py --port 5901 --user admin --password admin
"""

import argparse
import json
import socket
import struct
import sys
import threading

# Not a real image; the core test only checks that the bytes arrive intact.
FAKE_JPEG = b"\xff\xd8" + bytes(range(256)) * 40 + b"\xff\xd9"


def log(**event):
    print(json.dumps(event), flush=True)


def recv_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("client closed")
        buf += chunk
    return buf


def jpeg_update(width, height, data):
    msg = struct.pack(">BxH HHHHl", 0, 1, 0, 0, width, height, 7)
    length = len(data)
    if length <= 127:
        lb = bytes([0b10011111, length & 0x7F])
    elif length <= 16383:
        lb = bytes([0b10011111, length & 0x7F | 0x80, length >> 7 & 0x7F])
    else:
        lb = bytes([0b10011111, length & 0x7F | 0x80, length >> 7 & 0x7F | 0x80, length >> 14 & 0xFF])
    return msg + lb + data


def handle(conn, args):
    conn.sendall(b"RFB 003.008\n")
    version = recv_exact(conn, 12)
    log(event="version", value=version.decode())

    conn.sendall(bytes([1, 19]))  # one security type: VeNCrypt
    assert recv_exact(conn, 1)[0] == 19
    conn.sendall(bytes([0, 2]))
    assert recv_exact(conn, 2) == bytes([0, 2])
    conn.sendall(bytes([0]))
    conn.sendall(struct.pack(">BL", 1, 256))  # Plain only
    (subtype,) = struct.unpack(">L", recv_exact(conn, 4))
    assert subtype == 256, subtype
    ulen, plen = struct.unpack(">LL", recv_exact(conn, 8))
    user = recv_exact(conn, ulen).decode()
    passwd = recv_exact(conn, plen).decode()
    log(event="auth", user=user, password=passwd)
    if (user, passwd) != (args.user, args.password):
        reason = b"Invalid username or password"
        conn.sendall(struct.pack(">LL", 1, len(reason)) + reason)
        return
    conn.sendall(struct.pack(">L", 0))

    recv_exact(conn, 1)  # shared flag
    name = b"PiKVM"
    conn.sendall(struct.pack(">HH BB?? HHH BBB xxx L", args.width, args.height,
                             32, 24, False, True, 255, 255, 255, 16, 8, 0, len(name)) + name)

    lock = threading.Lock()
    frames_sent = 0
    while True:
        msg_type = recv_exact(conn, 1)[0]
        if msg_type == 0:
            pf = struct.unpack(">xxx BB?? HHH BBB xxx", recv_exact(conn, 19))
            log(event="set_pixel_format", bpp=pf[0], depth=pf[1], big_endian=pf[2],
                shifts=[pf[7], pf[8], pf[9]])
        elif msg_type == 2:
            (count,) = struct.unpack(">xH", recv_exact(conn, 3))
            encodings = list(struct.unpack(">" + "l" * count, recv_exact(conn, 4 * count)))
            log(event="set_encodings", encodings=encodings)
            if -258 in encodings:
                with lock:
                    conn.sendall(struct.pack(">BxH HHHHl", 0, 1, 0, 0, 0, 0, -258))
        elif msg_type == 3:
            incremental, x, y, w, h = struct.unpack(">?HHHH", recv_exact(conn, 9))
            log(event="fbur", incremental=incremental, w=w, h=h)
            if frames_sent < 3:
                frames_sent += 1
                with lock:
                    if frames_sent == 2:
                        # Resize like kvmd does when the source resolution changes.
                        conn.sendall(struct.pack(">BxH HHHHl", 0, 1, 0, 0, 1280, 720, -223))
                    conn.sendall(jpeg_update(args.width, args.height, FAKE_JPEG))
        elif msg_type == 4:
            down, keysym = struct.unpack(">?xxL", recv_exact(conn, 7))
            log(event="key", down=down, keysym=keysym)
        elif msg_type == 5:
            buttons, x, y = struct.unpack(">BHH", recv_exact(conn, 5))
            log(event="pointer", buttons=buttons, x=x, y=y)
        elif msg_type == 6:
            (length,) = struct.unpack(">xxxL", recv_exact(conn, 7))
            log(event="cut_text", text=recv_exact(conn, length).decode("utf-8"))
        elif msg_type == 255:
            sub, down, keysym, code = struct.unpack(">BHLL", recv_exact(conn, 11))
            assert sub == 0
            log(event="ext_key", down=bool(down), keysym=keysym, scancode=code)
        else:
            log(event="error", message=f"unknown message {msg_type}")
            return


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=5901)
    p.add_argument("--user", default="admin")
    p.add_argument("--password", default="admin")
    p.add_argument("--width", type=int, default=1920)
    p.add_argument("--height", type=int, default=1080)
    args = p.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", args.port))
    srv.listen(1)
    log(event="listening", port=args.port)
    while True:
        conn, _ = srv.accept()
        try:
            handle(conn, args)
        except ConnectionError:
            log(event="disconnected")
        finally:
            conn.close()
        sys.stdout.flush()


if __name__ == "__main__":
    main()
