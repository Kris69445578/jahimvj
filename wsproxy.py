#!/usr/bin/env python3
"""
wsproxy.py v8 — FastSSH-identical CONNECT response for zero-rated + normal data

Target client log (SSL OFF, zero-rated OR with data):

    HTTP/1.1 200 OK
    HTTP/1.1 101 Switching Protocols
    set auto replace response
    HTTP/1.1 200 OK
    SSH-2.0-dropbear_xxxx
    ssh authenticate with password
    ssh connected

Always dual 200 + 101 for every CONNECT (with or without data bundle).
SSH banner is appended in the same write so the tunnel never looks empty.
"""

import argparse
import asyncio
import base64
import hashlib
import logging
import socket

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("wsproxy")

WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def compute_ws_accept(ws_key: str) -> str:
    combined = ws_key.strip() + WS_MAGIC
    return base64.b64encode(hashlib.sha1(combined.encode("ascii")).digest()).decode("ascii")


def extract_ws_key(raw: bytes):
    for line in raw.split(b"\r\n"):
        if line.lower().startswith(b"sec-websocket-key:"):
            return line.split(b":", 1)[1].strip().decode("ascii", errors="replace")
    return None


def build_connect_response(brand: str, ws_key=None) -> bytes:
    """
    FastSSH-shaped dual response for CONNECT.

    Order the client must see:
      1) HTTP/1.1 200 OK
      2) HTTP/1.1 101 Switching Protocols   (+ optional Sec-WebSocket-Accept)
      3) SSH-2.0-dropbear_...   (appended by caller after this blob)
    """
    lines = [
        "HTTP/1.1 200 OK",
        "",
        f"HTTP/1.1 101 {brand}",
        "Connection: upgrade",
        "Upgrade: websocket",
    ]
    if ws_key:
        lines.append(f"Sec-WebSocket-Accept: {compute_ws_accept(ws_key)}")
    lines.append("")  # end of 101 headers
    return ("\r\n".join(lines) + "\r\n").encode()


def build_101(brand: str, ws_key=None) -> bytes:
    lines = [
        f"HTTP/1.1 101 {brand}",
        "Connection: upgrade",
        "Upgrade: websocket",
    ]
    if ws_key:
        lines.append(f"Sec-WebSocket-Accept: {compute_ws_accept(ws_key)}")
    lines.append("")
    return ("\r\n".join(lines) + "\r\n").encode()


MAX_HEADER_SIZE = 65536
HEADER_TIMEOUT = 12.0


async def read_request_block(reader, timeout=HEADER_TIMEOUT):
    buf = b""
    deadline = asyncio.get_event_loop().time() + timeout
    while b"\r\n\r\n" not in buf:
        remaining = deadline - asyncio.get_event_loop().time()
        if remaining <= 0:
            raise asyncio.TimeoutError
        chunk = await asyncio.wait_for(reader.read(4096), timeout=remaining)
        if not chunk:
            break
        buf += chunk
        if len(buf) > MAX_HEADER_SIZE:
            break
    return buf


def parse_first_line(raw):
    return raw.split(b"\r\n", 1)[0]


def has_websocket_upgrade(raw):
    lower = raw.lower()
    return b"upgrade:" in lower and b"websocket" in lower


def is_connect(first_line):
    return first_line.upper().startswith(b"CONNECT ")


def looks_like_http_request(block):
    parts = parse_first_line(block).split(b" ")
    return len(parts) >= 3 and parts[-1].upper().startswith(b"HTTP/")


def split_compound_payload(raw):
    sep = b"\r\n\r\n"
    idx = raw.find(sep)
    if idx == -1:
        return raw, None
    first = raw[: idx + len(sep)]
    second = raw[idx + len(sep) :]
    if not second.strip():
        return first, None
    return first, second


def set_sock_opts(writer):
    try:
        sock = writer.get_extra_info("socket")
        if sock is None:
            return
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        if hasattr(socket, "TCP_KEEPIDLE"):
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 30)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 10)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)
    except (OSError, AttributeError):
        pass


def cork(writer, enable):
    try:
        sock = writer.get_extra_info("socket")
        if sock is None:
            return
        if hasattr(socket, "TCP_CORK"):
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_CORK, 1 if enable else 0)
    except (OSError, AttributeError):
        pass


async def peek_ssh_banner(ssh_reader, wait=0.5):
    try:
        return await asyncio.wait_for(ssh_reader.read(256), timeout=wait)
    except (asyncio.TimeoutError, ConnectionResetError, OSError):
        return b""


async def pipe(src, dst):
    try:
        while True:
            chunk = await src.read(65536)
            if not chunk:
                break
            dst.write(chunk)
            await dst.drain()
    except (ConnectionResetError, BrokenPipeError, asyncio.IncompleteReadError, OSError):
        pass
    finally:
        try:
            dst.close()
        except Exception:
            pass


async def handle_client(reader, writer, ssh_host, ssh_port, brand):
    peer = writer.get_extra_info("peername", ("?", 0))
    set_sock_opts(writer)

    try:
        raw = await read_request_block(reader)
    except asyncio.TimeoutError:
        log.info("[%s] header timeout", peer)
        writer.close()
        return

    if not raw:
        writer.close()
        return

    first_block, second_block = split_compound_payload(raw)
    first_line = parse_first_line(first_block)

    if is_connect(first_line):
        intent = "CONNECT"
    elif has_websocket_upgrade(first_block):
        intent = "WEBSOCKET"
    elif second_block and has_websocket_upgrade(second_block):
        intent = "WEBSOCKET-CFRAY"
    else:
        intent = "HEALTH"

    ws_key = extract_ws_key(first_block)
    if ws_key is None and second_block:
        ws_key = extract_ws_key(second_block)

    log.info("[%s] %s intent=%s key=%s",
             peer, first_line[:90].decode("latin-1", errors="replace"),
             intent, "yes" if ws_key else "no")

    # Plain probes → 101 only (FastSSH does this too)
    if intent == "HEALTH":
        try:
            writer.write(build_101(brand, ws_key))
            await writer.drain()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        writer.close()
        return

    try:
        ssh_reader, ssh_writer = await asyncio.wait_for(
            asyncio.open_connection(ssh_host, ssh_port), timeout=8.0
        )
        set_sock_opts(ssh_writer)
    except (OSError, asyncio.TimeoutError) as exc:
        log.warning("[%s] backend %s:%d failed: %s", peer, ssh_host, ssh_port, exc)
        try:
            writer.write(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
            await writer.drain()
        except Exception:
            pass
        writer.close()
        return

    banner = await peek_ssh_banner(ssh_reader)
    if banner:
        log.info("[%s] banner %r", peer, banner[:48])
    else:
        log.warning("[%s] empty banner from %s:%d", peer, ssh_host, ssh_port)

    # CONNECT → always dual 200 + 101 (required for zero-rated carrier path)
    if intent == "CONNECT":
        handshake = build_connect_response(brand, ws_key)
    else:
        handshake = build_101(brand, ws_key)

    try:
        cork(writer, True)
        writer.write(handshake + banner)
        await writer.drain()
        cork(writer, False)
    except (BrokenPipeError, ConnectionResetError, OSError) as exc:
        log.warning("[%s] client write failed: %s", peer, exc)
        ssh_writer.close()
        writer.close()
        return

    if second_block and not looks_like_http_request(second_block):
        try:
            ssh_writer.write(second_block)
            await ssh_writer.drain()
        except (BrokenPipeError, ConnectionResetError, OSError):
            ssh_writer.close()
            writer.close()
            return

    await asyncio.gather(pipe(reader, ssh_writer), pipe(ssh_reader, writer))


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen-host", default="0.0.0.0")
    ap.add_argument("--listen-port", type=int, required=True)
    ap.add_argument("--ssh-host", default="127.0.0.1")
    ap.add_argument("--ssh-port", type=int, required=True)
    ap.add_argument("--brand", default="Switching Protocols")
    args = ap.parse_args()

    server = await asyncio.start_server(
        lambda r, w: handle_client(r, w, args.ssh_host, args.ssh_port, args.brand),
        args.listen_host,
        args.listen_port,
        reuse_address=True,
        reuse_port=True,
    )
    log.info("wsproxy v8 on %s -> %s:%d brand=%r",
             [s.getsockname() for s in server.sockets],
             args.ssh_host, args.ssh_port, args.brand)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
