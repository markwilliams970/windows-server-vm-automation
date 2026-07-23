#!/usr/bin/env python3
"""Grab a single QEMU framebuffer screenshot via QMP - no VNC client, no window
manager, no host display session required at all.

Requires the target qemu process to have been started with a QMP socket, e.g.:
    qemu-system-x86_64 ... -qmp unix:/path/to/qmp.sock,server,nowait

Usage:
    qmp-screenshot.py --socket /path/to/qmp.sock --out /path/to/shot.png
"""
import argparse
import json
import socket
import sys


def send(sock, obj):
    sock.sendall((json.dumps(obj) + "\n").encode())


def read_json_line(f):
    line = f.readline()
    if not line:
        raise RuntimeError("QMP socket closed unexpectedly")
    return json.loads(line)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--socket", required=True, help="Path to the QMP unix socket")
    ap.add_argument("--out", required=True, help="Output PNG path, writable by the qemu process itself (same host)")
    args = ap.parse_args()

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(args.socket)
    f = sock.makefile("rwb", buffering=0)

    read_json_line(f)  # greeting banner

    send(sock, {"execute": "qmp_capabilities"})
    resp = read_json_line(f)
    if "error" in resp:
        sys.exit(f"qmp_capabilities failed: {resp['error']}")

    send(sock, {"execute": "screendump", "arguments": {"filename": args.out, "format": "png"}})
    resp = read_json_line(f)
    if "error" in resp:
        sys.exit(f"screendump failed: {resp['error']}")

    print(args.out)


if __name__ == "__main__":
    main()
