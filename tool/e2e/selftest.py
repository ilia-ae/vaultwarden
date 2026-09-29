#!/usr/bin/env python3
"""End-to-end self-test of the local stack and harness (no app code involved).

  1. bwproto known-answer tests (sdk-internal vectors)
  2. /alive on every base; mTLS front: handshake must FAIL without a client cert and with the
     foreign-CA / expired certs, and succeed with the good one
  3. requester.py + approver_ref.py approve round trip for every account on
     VA_E2E_BASE (1.37.1 direct), VA_E2E_MTLS_BASE (Caddy mTLS) and VA_E2E_VW137_BASE (1.37.3)
  4. deny round trip (Vaultwarden deletes the request; requester sees "doesn't exist")
  5. realtime: the approver's /notifications/hub WebSocket (SignalR/MessagePack) receives the
     AuthRequest push for a new request, both direct and through Caddy with mTLS

Run with the harness venv:  .venv/bin/python selftest.py [--quick]
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import socket
import ssl
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

import requests

import bwproto as bw
import e2e_config as cfg

PY = sys.executable
RESULTS: list[tuple[str, bool, str]] = []


def record(name: str, ok: bool, detail: str = "") -> None:
    RESULTS.append((name, ok, detail))
    print(f"[{'PASS' if ok else 'FAIL'}] {name}{' - ' + detail if detail else ''}", flush=True)


# ─────────────────────────────────────────────────────────────── TLS checks


def tls_get(host: str, port: int, path: str, cert: tuple[Path, Path] | None) -> str:
    ctx = ssl.create_default_context(cafile=str(cfg.CA_PEM))
    if cert:
        ctx.load_cert_chain(str(cert[0]), str(cert[1]))
    with socket.create_connection((host, port), timeout=10) as raw:
        with ctx.wrap_socket(raw, server_hostname=host) as tls:
            tls.sendall(f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nConnection: close\r\n\r\n".encode())
            data = b""
            while chunk := tls.recv(4096):
                data += chunk
    return data.split(b"\r\n", 1)[0].decode()


def check_mtls() -> None:
    u = urlparse(cfg.MTLS_BASE)
    host, port = u.hostname or "localhost", u.port or 443
    status = tls_get(host, port, "/alive", (cfg.CLIENT_CRT, cfg.CLIENT_KEY))
    record("mTLS: client cert accepted", status.startswith("HTTP/1.1 200"), status)
    for label, cert in [
        ("no client cert", None),
        ("foreign-CA cert", (cfg.PKI_DIR / "client-foreign.crt", cfg.PKI_DIR / "client-foreign.key")),
        ("expired cert", (cfg.PKI_DIR / "client-expired.crt", cfg.PKI_DIR / "client-expired.key")),
    ]:
        try:
            status = tls_get(host, port, "/alive", cert)
            record(f"mTLS: {label} rejected", False, f"got {status!r}")
        except (ssl.SSLError, ConnectionError, OSError) as err:
            record(f"mTLS: {label} rejected", True, type(err).__name__ + ": " + str(err)[:90])


# ─────────────────────────────────────────────────────────────── round trips


def run_roundtrip(base: str, account: str, *, deny: bool = False) -> None:
    name = f"{'deny' if deny else 'approve'} {account} @ {base}"
    req_cmd = [PY, "requester.py", "--account", account, "--base", base, "--json", "--timeout", "90"]
    if deny:
        req_cmd += ["--expect", "deny"]
    proc = subprocess.Popen(req_cmd, cwd=cfg.HERE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    assert proc.stdout is not None
    created = None
    lines: list[str] = []
    for line in proc.stdout:
        lines.append(line.rstrip())
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("event") == "created":
            created = ev
            break
        if ev.get("event") == "error":
            break
    if not created:
        proc.wait(timeout=30)
        record(name, False, "requester did not create a request: " + " | ".join(lines[-3:]))
        return
    appr_cmd = [PY, "approver_ref.py", "--account", account, "--base", base, "--json"]
    appr_cmd += ["--request-id", created["id"], "--expect-fingerprint", created["fingerprint"]]
    if deny:
        appr_cmd.append("--deny")
    appr = subprocess.run(appr_cmd, cwd=cfg.HERE, capture_output=True, text=True, timeout=180)
    rest = proc.stdout.read()
    rc = proc.wait(timeout=120)
    lines += rest.splitlines()
    last = json.loads(lines[-1]) if lines and lines[-1].startswith("{") else {}
    ok = appr.returncode == 0 and rc == 0
    detail = f"requester rc={rc} last={last.get('event')} {last.get('checks') or last.get('message') or ''}".strip()
    if appr.returncode != 0:
        detail += f"; approver rc={appr.returncode}: {appr.stdout.strip()[-200:]} {appr.stderr.strip()[-200:]}"
    record(name, ok, detail + f"; phrase {created['fingerprint']}")


# ─────────────────────────────────────────────────────────────── WebSocket hub


class MiniWebSocket:
    """Just enough RFC 6455 for a SignalR MessagePack client (client frames are masked)."""

    def __init__(self, base: str, path: str):
        u = urlparse(base)
        self.host, secure = u.hostname or "localhost", u.scheme == "https"
        port = u.port or (443 if secure else 80)
        raw = socket.create_connection((self.host, port), timeout=15)
        if secure:
            ctx = ssl.create_default_context(cafile=str(cfg.CA_PEM))
            ctx.set_alpn_protocols(["http/1.1"])
            if base.rstrip("/") == cfg.MTLS_BASE.rstrip("/"):
                ctx.load_cert_chain(str(cfg.CLIENT_CRT), str(cfg.CLIENT_KEY))
            raw = ctx.wrap_socket(raw, server_hostname=self.host)
        self.sock = raw
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(
            (
                f"GET {path} HTTP/1.1\r\nHost: {self.host}:{port}\r\nUpgrade: websocket\r\n"
                f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
            ).encode()
        )
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(1)
            if not chunk:
                raise ConnectionError("closed during upgrade")
            head += chunk
        self.status = head.split(b"\r\n", 1)[0].decode()
        if " 101 " not in self.status + " ":
            raise ConnectionError(f"upgrade refused: {self.status}")

    def send(self, payload: bytes, opcode: int = 0x1) -> None:
        mask = os.urandom(4)
        n = len(payload)
        header = bytes([0x80 | opcode])
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 65536:
            header += bytes([0x80 | 126]) + n.to_bytes(2, "big")
        else:
            header += bytes([0x80 | 127]) + n.to_bytes(8, "big")
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def _exact(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("socket closed")
            buf += chunk
        return buf

    def recv(self, timeout: float) -> tuple[int, bytes]:
        self.sock.settimeout(timeout)
        b1, b2 = self._exact(2)
        n = b2 & 0x7F
        if n == 126:
            n = int.from_bytes(self._exact(2), "big")
        elif n == 127:
            n = int.from_bytes(self._exact(8), "big")
        return b1 & 0x0F, self._exact(n)

    def close(self) -> None:
        try:
            self.send(b"\x03\xe8", opcode=0x8)
        finally:
            self.sock.close()


def check_hub(base: str) -> None:
    name = f"hub push for new auth request @ {base}"
    acc = cfg.ACCOUNTS["pbkdf2"]
    state = bw.State()
    device, _ = bw.new_device(state, base, acc.email, "hub-listener", bw.DEVICE_IOS, "va-e2e-hub")
    client = bw.BwClient(base, device, client_id="mobile")
    login = client.login_password(acc.email, acc.password)
    try:
        ws = MiniWebSocket(base, f"/notifications/hub?access_token={login.access_token}")
    except (ConnectionError, OSError, ssl.SSLError) as err:
        record(name, False, f"upgrade failed: {err}")
        return
    try:
        ws.send(b'{"protocol":"messagepack","version":1}\x1e')
        # The handshake reply is "{}\x1e"; SignalR pings (b"\x02\x91\x06") may arrive around it.
        handshake_deadline = time.monotonic() + 10
        while True:
            opcode, data = ws.recv(max(0.1, handshake_deadline - time.monotonic()))
            if data.startswith(b"{}"):
                break
            if time.monotonic() > handshake_deadline:
                record(name, False, f"no handshake reply, last frame {data[:40]!r}")
                return
        out = subprocess.run(
            [PY, "requester.py", "--account", "pbkdf2", "--base", base, "--json", "--no-wait"],
            cwd=cfg.HERE,
            capture_output=True,
            text=True,
            timeout=60,
        )
        created = json.loads(out.stdout.splitlines()[0])
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            opcode, data = ws.recv(deadline - time.monotonic())
            if opcode == 0x9:  # ping -> pong
                ws.send(data, opcode=0xA)
                continue
            if created["id"].encode() in data:
                record(name, True, f"{ws.status}; frame with request id {created['id'][:8]}... received")
                # clean up: deny the pending request so it does not linger in lists
                subprocess.run(
                    [PY, "approver_ref.py", "--account", "pbkdf2", "--base", base, "--deny",
                     "--request-id", created["id"], "--json"],
                    cwd=cfg.HERE, capture_output=True, text=True, timeout=120,
                )  # fmt: skip
                return
        record(name, False, "no hub message carrying the request id within 15 s")
    except (TimeoutError, socket.timeout):
        record(name, False, "timed out waiting for hub frames")
    finally:
        ws.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--quick", action="store_true", help="only the pbkdf2 account per base")
    args = parser.parse_args()

    bw._selftest()
    for base in (cfg.BASE, cfg.MTLS_BASE, cfg.VW137_BASE):
        tls = cfg.tls_kwargs(base)
        try:
            r = requests.get(base + "/alive", verify=tls["verify"], cert=tls["cert"], timeout=10)
            record(f"alive {base}", r.ok, r.text.strip())
        except requests.RequestException as err:
            record(f"alive {base}", False, str(err)[:120])
    check_mtls()

    accounts = ["pbkdf2"] if args.quick else list(cfg.ACCOUNTS)
    for base in (cfg.BASE, cfg.MTLS_BASE, cfg.VW137_BASE):
        for account in accounts:
            run_roundtrip(base, account)
    run_roundtrip(cfg.BASE, "pbkdf2", deny=True)
    run_roundtrip(cfg.MTLS_BASE, "totp", deny=True)
    check_hub(cfg.BASE)
    check_hub(cfg.MTLS_BASE)

    failed = [r for r in RESULTS if not r[1]]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
