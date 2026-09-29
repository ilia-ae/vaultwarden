#!/usr/bin/env python3
"""Reference approver: does what VaultApprover does, in Python, to prove the harness.

Logs in with the master password as its own device (DeviceType iOS, name "Vault Approver"
like the app), lists pending auth requests (GET /api/auth-requests), picks one, shows its
fingerprint phrase and answers it with the app's exact approve format:

  PUT /api/auth-requests/{id}
  {"key": "4." + b64(RSA-OAEP-SHA1(request.publicKey, userKey[64])),
   "masterPasswordHash": null, "deviceIdentifier": <approver device id>, "requestApproved": true}

Deny sends requestApproved=false with key "" (as the app does). Exit 0 on success,
3 if the phrase does not match --expect-fingerprint, 4 if no pending request appeared.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from typing import Any

import bwproto as bw
import e2e_config as cfg


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--account", default="pbkdf2", help="account key or email from e2e_config (default pbkdf2)")
    p.add_argument("--email")
    p.add_argument("--password")
    p.add_argument("--totp-secret")
    p.add_argument("--base", help=f"server base URL (default VA_E2E_BASE={cfg.BASE})")
    p.add_argument("--mtls", action="store_true", help=f"use the mTLS front {cfg.MTLS_BASE}")
    p.add_argument("--request-id", help="answer this request (default: the newest pending one)")
    p.add_argument("--expect-fingerprint", help="refuse to approve unless the phrase matches")
    p.add_argument("--deny", action="store_true")
    p.add_argument("--wait", type=float, default=30.0, help="seconds to wait for a pending request")
    p.add_argument("--list", action="store_true", help="only print the pending list")
    p.add_argument("--json", action="store_true")
    args = p.parse_args()

    acc = cfg.account(args.account) if not args.email else None
    email = args.email or acc.email
    password = args.password or (acc.password if acc else None)
    totp_secret = args.totp_secret or (acc.totp_secret if acc else None)
    if not password:
        p.error("--password is required with --email")
    base = cfg.MTLS_BASE if args.mtls else (args.base or cfg.BASE)

    def emit(event: str, text: str, **fields: Any) -> None:
        print(json.dumps({"event": event, **fields}) if args.json else text, flush=True)

    state = bw.State()
    device, _ = bw.new_device(state, base, email, "approver", bw.DEVICE_IOS, "Vault Approver")
    client = bw.BwClient(base, device, client_id="mobile")
    try:
        login = client.login_password(email, password, totp_secret=totp_secret, state=state, state_role="approver")
    except bw.ApiError as err:
        emit("error", f"login failed: {err.message}", stage="login", message=err.message)
        return 1
    assert login.user_key is not None

    deadline = time.monotonic() + args.wait
    target: dict[str, Any] | None = None
    while True:
        listing = client.request("GET", "/api/auth-requests")
        pending = listing.get("data") or listing.get("Data") or []
        if args.list:
            for r in pending:
                phrase = bw.auth_request_fingerprint(email, bw.b64d(r["publicKey"]))
                emit(
                    "pending",
                    f"{r['id']}  {r.get('creationDate')}  {r.get('requestDeviceType')}  "
                    f"{r.get('requestIpAddress')}  {phrase}",
                    id=r["id"],
                    fingerprint=phrase,
                    creationDate=r.get("creationDate"),
                    requestDeviceType=r.get("requestDeviceType"),
                    requestIpAddress=r.get("requestIpAddress"),
                )
            return 0
        if args.request_id:
            target = next((r for r in pending if r["id"] == args.request_id), None)
        elif pending:
            target = max(pending, key=lambda r: r.get("creationDate") or "")
        if target or time.monotonic() > deadline:
            break
        time.sleep(1.0)
    if not target:
        emit("error", "no matching pending auth request", stage="list")
        return 4

    spki = bw.b64d(target["publicKey"])
    phrase = bw.auth_request_fingerprint(email, spki)
    emit(
        "found",
        f"request {target['id']} from {target.get('requestDeviceType')} @ {target.get('requestIpAddress')}\n"
        f"fingerprint: {phrase}",
        id=target["id"],
        fingerprint=phrase,
    )
    if args.expect_fingerprint and args.expect_fingerprint != phrase:
        emit("error", f"fingerprint mismatch: expected {args.expect_fingerprint}", stage="fingerprint")
        return 3

    approve = not args.deny
    body = {
        "key": bw.rsa_encrypt(spki, login.user_key.to_bytes(), enc_type=4) if approve else "",
        "masterPasswordHash": None,
        "deviceIdentifier": device.identifier,
        "requestApproved": approve,
    }
    try:
        resp = client.request("PUT", f"/api/auth-requests/{target['id']}", json=body)
    except bw.ApiError as err:
        emit("error", f"PUT failed: {err.message}", stage="put", status=err.status, message=err.message)
        return 1
    emit(
        "approved" if approve else "denied",
        f"{'approved' if approve else 'denied'} {target['id']} (server requestApproved={resp.get('requestApproved')})",
        id=target["id"],
        requestApproved=resp.get("requestApproved"),
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
