#!/usr/bin/env python3
"""Account operations the Dart e2e tests (test/e2e/server_e2e_test.dart) need from the harness.

  register         create a throwaway PBKDF2 account (fresh email per test run), optionally
                   with authenticator (TOTP) 2FA enabled with a given secret
  change-password  change the master password through the API, as the web vault does:
                   the user key stays the same and is re-wrapped with the new master key.
                   Vaultwarden then resets the security stamp, which rotates the refresh
                   token of every device (the app's refresh token dies) and sends a hub
                   LogOut to the account's other sessions.

Every command prints one JSON object on stdout and exits 0 on success, 1 on failure.
Run it with the harness venv, e.g.  .venv/bin/python ops.py register --email x@e2e.test ...
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any

import bwproto as bw
import e2e_config as cfg


def _emit(**fields: Any) -> None:
    print(json.dumps(fields), flush=True)


def cmd_register(args: argparse.Namespace) -> int:
    base = cfg.MTLS_BASE if args.mtls else (args.base or cfg.BASE)
    kdf = bw.Kdf(bw.KDF_PBKDF2, args.iterations)
    state = bw.State()
    device, _ = bw.new_device(state, base, args.email, "ops", bw.DEVICE_CHROME, "va-e2e-ops")
    client = bw.BwClient(base, device)
    try:
        client.register(args.email, args.password, kdf)
        created = True
    except bw.ApiError as err:
        if "already exists" not in err.message:
            raise
        created = False
    server_kdf = client.prelogin(args.email)
    totp = False
    if args.totp_secret:
        # Enable 2FA right away, while a plain password login still works. Vaultwarden marks
        # the current time step as used, so the next TOTP login needs a later step.
        login = client.login_password(args.email, args.password, state=state, state_role="ops")
        providers = client.request("GET", "/api/two-factor")
        enabled = any(p.get("type") == 0 and p.get("enabled") for p in providers.get("data", []))
        if not enabled:
            client.request(
                "POST",
                "/api/two-factor/authenticator",
                json={
                    "key": args.totp_secret,
                    "token": bw.totp(args.totp_secret),
                    "masterPasswordHash": bw.master_password_hash(login.extra["master_key"], args.password),
                },
            )
        totp = True
    _emit(
        ok=True,
        created=created,
        email=args.email,
        kdf=server_kdf.type,
        iterations=server_kdf.iterations,
        totp=totp,
    )
    return 0


def cmd_change_password(args: argparse.Namespace) -> int:
    base = cfg.MTLS_BASE if args.mtls else (args.base or cfg.BASE)
    state = bw.State()
    device, _ = bw.new_device(state, base, args.email, "ops", bw.DEVICE_CHROME, "va-e2e-ops")
    client = bw.BwClient(base, device)
    login = client.login_password(args.email, args.password, state=state, state_role="ops")
    assert login.user_key is not None
    kdf: bw.Kdf = login.extra["kdf"]
    old_hash = bw.master_password_hash(login.extra["master_key"], args.password)
    new_master = bw.make_master_key(args.new_password, args.email, kdf)
    new_hash = bw.master_password_hash(new_master, args.new_password)
    new_key = bw.enc_string_encrypt(login.user_key.to_bytes(), bw.stretch_master_key(new_master))
    client.request(
        "POST",
        "/api/accounts/password",
        json={
            "masterPasswordHash": old_hash,
            "newMasterPasswordHash": new_hash,
            "masterPasswordHint": None,
            "key": new_key,
        },
    )
    # Prove the new password works and still unwraps the same user key.
    check = bw.BwClient(base, device)
    relogin = check.login_password(args.email, args.new_password, state=state, state_role="ops")
    same_key = relogin.user_key == login.user_key
    _emit(ok=same_key, email=args.email, harnessDeviceId=device.identifier, sameUserKey=same_key)
    return 0 if same_key else 1


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    reg = sub.add_parser("register", help="create a throwaway PBKDF2 account")
    reg.add_argument("--email", required=True)
    reg.add_argument("--password", required=True)
    reg.add_argument("--iterations", type=int, default=600_000)
    reg.add_argument("--totp-secret", help="base32 secret: also enable authenticator 2FA")
    reg.add_argument("--base")
    reg.add_argument("--mtls", action="store_true")
    reg.set_defaults(func=cmd_register)

    chg = sub.add_parser("change-password", help="change the master password (keeps the user key)")
    chg.add_argument("--email", required=True)
    chg.add_argument("--password", required=True)
    chg.add_argument("--new-password", required=True)
    chg.add_argument("--base")
    chg.add_argument("--mtls", action="store_true")
    chg.set_defaults(func=cmd_change_password)

    args = p.parse_args()
    try:
        return args.func(args)
    except bw.ApiError as err:
        _emit(ok=False, status=err.status, message=err.message)
        return 1
    except Exception as err:  # noqa: BLE001 - report anything as a JSON failure line
        _emit(ok=False, message=repr(err))
        return 1


if __name__ == "__main__":
    sys.exit(main())
