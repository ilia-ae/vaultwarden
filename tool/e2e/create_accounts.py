#!/usr/bin/env python3
"""Create (idempotently) the synthetic e2e accounts on the local Vaultwarden instances.

  pbkdf2@e2e.test  PBKDF2-SHA256 600000
  argon@e2e.test   Argon2id 64 MiB / 3 iterations / 4 lanes
  totp@e2e.test    PBKDF2-SHA256 600000 + authenticator (TOTP) 2FA with a fixed secret

Default targets: VA_E2E_BASE (1.37.1; the mTLS front shares its database) and
VA_E2E_VW137_BASE (1.37.3). Existing accounts are verified by logging in, not recreated.
Writes tool/e2e/.state/e2e.env with the values the Dart e2e tests read.
"""

from __future__ import annotations

import argparse
import sys

import bwproto as bw
import e2e_config as cfg


def ensure_account(base: str, acc: cfg.Account, state: bw.State) -> None:
    kdf = bw.Kdf(acc.kdf, acc.iterations, acc.memory, acc.parallelism)
    device, _ = bw.new_device(state, base, acc.email, "setup", bw.DEVICE_CHROME, "va-e2e-setup")
    client = bw.BwClient(base, device)
    try:
        client.register(acc.email, acc.password, kdf)
        print(f"  {acc.email}: registered ({'PBKDF2' if acc.kdf == 0 else 'Argon2id'})")
    except bw.ApiError as err:
        if "already exists" not in err.message:
            raise
        print(f"  {acc.email}: exists")

    server_kdf = client.prelogin(acc.email)
    if server_kdf != kdf:
        raise SystemExit(f"{acc.email}: server KDF {server_kdf} != expected {kdf}; run teardown and retry")

    login = client.login_password(
        acc.email, acc.password, totp_secret=acc.totp_secret, state=state, state_role="setup"
    )
    assert login.user_key is not None and login.private_key is not None
    bw.spki_from_private(login.private_key)  # the user's RSA key decrypts and parses

    if acc.totp_secret:
        providers = client.request("GET", "/api/two-factor")
        enabled = any(p.get("type") == 0 and p.get("enabled") for p in providers.get("data", []))
        if not enabled:
            master_hash = bw.master_password_hash(login.extra["master_key"], acc.password)
            client.request(
                "POST",
                "/api/two-factor/authenticator",
                json={"key": acc.totp_secret, "token": bw.totp(acc.totp_secret), "masterPasswordHash": master_hash},
            )
            print(f"  {acc.email}: TOTP enabled (secret {acc.totp_secret})")
            # Prove the 2FA login path end to end (fresh device => no remember token yet).
            dev2, _ = bw.new_device(state, base, acc.email, "setup-2fa", bw.DEVICE_CHROME, "va-e2e-setup-2fa")
            probe = bw.BwClient(base, dev2)
            try:
                probe.login_password(acc.email, acc.password)
                raise SystemExit(f"{acc.email}: login without 2FA unexpectedly succeeded")
            except bw.TwoFactorRequired as tfr:
                assert 0 in tfr.providers, tfr.providers
            probe.login_password(acc.email, acc.password, totp_secret=acc.totp_secret, state=state, state_role="setup-2fa")
        else:
            print(f"  {acc.email}: TOTP already enabled")
    print(f"  {acc.email}: login OK (user key + private key decrypt)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", action="append", help="server base URL (repeatable); default: 1.37.1 + 1.37.3")
    parser.add_argument("--account", action="append", help="account key or email (repeatable); default: all")
    args = parser.parse_args()

    bases = args.base or [cfg.BASE, cfg.VW137_BASE]
    accounts = [cfg.account(a) for a in args.account] if args.account else list(cfg.ACCOUNTS.values())
    state = bw.State()
    for base in bases:
        print(f"{base}:")
        for acc in accounts:
            ensure_account(base, acc, state)

    cfg.STATE_DIR.mkdir(parents=True, exist_ok=True)
    env_path = cfg.STATE_DIR / "e2e.env"
    env_path.write_text("\n".join(cfg.env_lines()) + "\n")
    print(f"\nwrote {env_path}:")
    print("\n".join(cfg.env_lines()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
