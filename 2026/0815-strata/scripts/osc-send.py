#!/usr/bin/env python3
"""依存なしの最小 OSC 送信。

    python3 scripts/osc-send.py /scene 2
    python3 scripts/osc-send.py /param/elevationScale 1.4
    python3 scripts/osc-send.py /scene/next

引数は int / float / str を見た目から判定する（"1" は int、"1.0" は float）。
送り先は既定で 127.0.0.1:9000（STRATA_OSC_PORT / STRATA_OSC_HOST で変更）。

pip 依存を入れずに OSC を打てるようにしてあるのは、30 分の無人稼働ソークを
CI 的に何度も回し直すため（外部パッケージを前提にすると環境で詰まる）。
"""
import os
import socket
import struct
import sys


def _pad(data: bytes) -> bytes:
    """OSC は 4 バイト境界。終端 NUL を含めてパディングする。"""
    data += b"\x00"
    while len(data) % 4:
        data += b"\x00"
    return data


def encode(address: str, args) -> bytes:
    tags = ","
    body = b""
    for a in args:
        if isinstance(a, int):
            tags += "i"
            body += struct.pack(">i", a)
        elif isinstance(a, float):
            tags += "f"
            body += struct.pack(">f", a)
        else:
            tags += "s"
            body += _pad(str(a).encode("utf-8"))
    return _pad(address.encode("utf-8")) + _pad(tags.encode("utf-8")) + body


def parse(token: str):
    try:
        return int(token)
    except ValueError:
        pass
    try:
        return float(token)
    except ValueError:
        return token


def send(address: str, args, host=None, port=None) -> None:
    host = host or os.environ.get("STRATA_OSC_HOST", "127.0.0.1")
    port = int(port or os.environ.get("STRATA_OSC_PORT", "9000"))
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.sendto(encode(address, args), (host, port))
    finally:
        sock.close()


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    address = sys.argv[1]
    args = [parse(t) for t in sys.argv[2:]]
    send(address, args)
    print(f"sent {address} {args}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
