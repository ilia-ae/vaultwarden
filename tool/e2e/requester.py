#!/usr/bin/env python3
"""Play the NEW device of a "Log in with device" flow against the local e2e stack.

1. Makes sure this requester device is a known device of the account (Vaultwarden only
   accepts auth requests from a device that already logged in with the same device type),
   using a one-time password login; the device id is kept in .state/state.json.
2. POST /api/auth-requests anonymously with a fresh RSA-2048 key pair and access code, and
   prints the request id and the Bitwarden fingerprint phrase (email.lower() + SPKI).
3. Polls GET /api/auth-requests/{id}/response?code=<accessCode>.
4. On approval: decrypts the user key (RSA-OAEP), logs in with grant_type=password +
   authRequest=<id> + password=<accessCode>, then proves the key: decrypts (MAC-checked) the
   account private key from the token response and checks it against the user's public key,
   and compares with the user key unwrapped from "Key" with the master password.

Exit codes: 0 expected outcome, 2 approved but key/login verification failed, 3 denied,
4 timed out (no answer), 5 approved but login rejected (e.g. after the 5-minute window),
1 usage/other errors. With --expect deny, a denial exits 0 and an approval exits 3.

--json prints one JSON object per line (events: created, answered, verified / denied /
timeout / error) for tests that drive this script as a subprocess.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from typing import Any

import bwproto as bw
import e2e_config as cfg

EXIT_OK, EXIT_ERROR, EXIT_VERIFY, EXIT_DENIED, EXIT_TIMEOUT, EXIT_LOGIN = 0, 1, 2, 3, 4, 5


class Out:
    def __init__(self, as_json: bool):
        self.as_json = as_json

    def event(self, name: str, text: str, **fields: Any) -> None:
        if self.as_json:
            payload = {"event": name, **fields}
            if name in ("error", "denied", "timeout"):
                payload.setdefault("message", text)
            print(json.dumps(payload), flush=True)
        else:
            print(text, flush=True)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--account", default="pbkdf2", help="account key or email from e2e_config (default pbkdf2)")
    p.add_argument("--email", help="override email (with --password)")
    p.add_argument("--password", help="override master password")
    p.add_argument("--totp-secret", help="override TOTP secret (default: the account's)")
    p.add_argument("--base", help=f"server base URL (default VA_E2E_BASE={cfg.BASE})")
    p.add_argument("--mtls", action="store_true", help=f"use the mTLS front {cfg.MTLS_BASE}")
    p.add_argument("--device-type", type=int, default=bw.DEVICE_CHROME, help="Bitwarden DeviceType (9 Chrome)")
    p.add_argument("--device-name", default="va-e2e-requester")
    p.add_argument("--client-ip", help="send X-Real-IP (direct ports only) to fake the requester IP")
    p.add_argument("--timeout", type=float, default=300.0, help="seconds to wait for an answer")
    p.add_argument("--poll", type=float, default=2.0, help="poll interval, seconds")
    p.add_argument("--login-delay", type=float, default=0.0, help="wait this long after approval before login")
    p.add_argument("--no-wait", action="store_true", help="only create the request and exit 0")
    p.add_argument("--expect", choices=["approve", "deny"], default="approve")
    p.add_argument("--json", action="store_true", help="JSON-lines output")
    args = p.parse_args()

    out = Out(args.json)
    acc = cfg.account(args.account) if not args.email else None
    email = args.email or acc.email
    password = args.password or (acc.password if acc else None)
    totp_secret = args.totp_secret or (acc.totp_secret if acc else None)
    if not password:
        p.error("--password is required with --email")
    base = cfg.MTLS_BASE if args.mtls else (args.base or cfg.BASE)
    state = bw.State()
    role = f"requester-{args.device_type}"

    try:
        # 1. known device of the same type
        device, st = bw.new_device(state, base, email, role, args.device_type, args.device_name)
        client = bw.BwClient(base, device, client_ip=args.client_ip)
        if not st.get("registered"):
            client.login_password(email, password, totp_secret=totp_secret, state=state, state_role=role)
            st = state.get(bw.state_key(base, email, role))
            st["registered"] = True
            state.put(bw.state_key(base, email, role), st)
        client.access_token = None  # from here on the requester is anonymous

        # 2. create the auth request
        pkcs8, spki = bw.generate_rsa_keypair()
        code = bw.access_code()
        created = client.request(
            "POST",
            "/api/auth-requests",
            auth=False,
            json={
                "email": email,
                "publicKey": bw.b64e(spki),
                "deviceIdentifier": device.identifier,
                "accessCode": code,
                "type": 0,  # AuthenticateAndUnlock
            },
        )
        request_id = created["id"]
        phrase = bw.auth_request_fingerprint(email, spki)
        out.event(
            "created",
            f"request id:   {request_id}\nfingerprint:  {phrase}\nemail:        {email}\n"
            f"server:       {base}\ncreated:      {created.get('creationDate')}\n"
            f"device type:  {created.get('requestDeviceType')} ({args.device_type})\n"
            f"request ip:   {created.get('requestIpAddress')}",
            id=request_id,
            fingerprint=phrase,
            email=email,
            base=base,
            creationDate=created.get("creationDate"),
            requestDeviceType=created.get("requestDeviceType"),
            requestIpAddress=created.get("requestIpAddress"),
            deviceIdentifier=device.identifier,
        )
        if args.no_wait:
            return EXIT_OK

        # 3. wait for the answer
        started = time.monotonic()
        answer: dict[str, Any] | None = None
        while time.monotonic() - started < args.timeout:
            try:
                resp = client.request("GET", f"/api/auth-requests/{request_id}/response?code={code}", auth=False)
            except bw.ApiError as err:
                # Vaultwarden deletes a denied request -> "AuthRequest doesn't exist".
                if err.status in (400, 404) and "doesn't exist" in err.message:
                    out.event("denied", "denied (request deleted by the server)", id=request_id)
                    return EXIT_OK if args.expect == "deny" else EXIT_DENIED
                raise
            if resp.get("requestApproved") is False and resp.get("responseDate"):
                out.event("denied", "denied (requestApproved=false)", id=request_id)
                return EXIT_OK if args.expect == "deny" else EXIT_DENIED
            if resp.get("requestApproved") and resp.get("key"):
                answer = resp
                break
            time.sleep(args.poll)
        if answer is None:
            out.event("timeout", f"no answer within {args.timeout:.0f}s", id=request_id)
            return EXIT_TIMEOUT
        latency = time.monotonic() - started
        enc_key: str = answer["key"]
        out.event(
            "answered",
            f"approved after {latency:.1f}s; key type {enc_key.split('.', 1)[0]}, "
            f"masterPasswordHash={'set' if answer.get('masterPasswordHash') else 'null'}",
            id=request_id,
            keyType=enc_key.split(".", 1)[0],
            masterPasswordHash=answer.get("masterPasswordHash"),
            responseDate=answer.get("responseDate"),
        )
        if args.expect == "deny":
            return EXIT_DENIED

        # 4. decrypt the user key and log in with the auth request
        try:
            user_key = bw.SymKey.from_bytes(bw.rsa_decrypt(pkcs8, enc_key))
        except Exception as err:  # noqa: BLE001 - report any decrypt failure as verification failure
            out.event("error", f"cannot decrypt approved key: {err}", id=request_id, stage="decrypt")
            return EXIT_VERIFY
        if user_key.mac is None:
            out.event("error", "approved key is not a 64-byte user key", id=request_id, stage="decrypt")
            return EXIT_VERIFY
        if args.login_delay:
            time.sleep(args.login_delay)
        try:
            token = client.login(
                email, code, auth_request_id=request_id, totp_secret=totp_secret, state=state, state_role=role
            )
        except bw.ApiError as err:
            out.event("error", f"auth-request login rejected: {err.message}", id=request_id, stage="login")
            return EXIT_LOGIN

        # 5. prove the key
        checks: dict[str, bool] = {}
        try:
            private = bw.enc_string_decrypt(token["PrivateKey"], user_key)  # MAC verified
            spki_user = bw.spki_from_private(private)
            checks["privateKeyDecrypts"] = True
            sync = client.request("GET", "/api/sync?excludeDomains=true")
            profile = sync.get("profile") or {}
            pair = (profile.get("accountKeys") or {}).get("publicKeyEncryptionKeyPair") or {}
            server_pub = pair.get("publicKey")
            if not server_pub:
                server_pub = client.request("GET", f"/api/users/{profile['id']}/public-key")["publicKey"]
            checks["publicKeyMatches"] = bw.b64d(server_pub) == spki_user
        except Exception as err:  # noqa: BLE001
            out.event("error", f"private key check failed: {err}", id=request_id, stage="verify")
            return EXIT_VERIFY
        kdf = bw.Kdf.from_json(token)
        master_key = bw.make_master_key(password, email, kdf)
        checks["matchesMasterKeyUnwrap"] = bw.decrypt_user_key(token["Key"], master_key) == user_key
        ok = all(checks.values())
        out.event(
            "verified" if ok else "error",
            f"login with auth request OK; checks: {checks}",
            id=request_id,
            checks=checks,
            latencySeconds=round(latency, 2),
        )
        return EXIT_OK if ok else EXIT_VERIFY
    except bw.ApiError as err:
        out.event("error", f"server error: {err}", stage="api", status=err.status, message=err.message)
        return EXIT_ERROR
    except Exception as err:  # noqa: BLE001
        out.event("error", f"error: {err!r}", stage="unexpected")
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
