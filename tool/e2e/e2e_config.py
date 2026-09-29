"""Shared configuration of the local VaultApprover e2e stack (see README.md).

Every value can be overridden with the same VA_E2E_* environment variable the Dart e2e
tests read, so the Python harness and the Dart tests always agree.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
PKI_DIR = HERE / ".pki"
STATE_DIR = HERE / ".state"
WORDLIST_DART = REPO_ROOT / "lib" / "utils" / "eff_wordlist.dart"


def _env(name: str, default: str) -> str:
    value = os.environ.get(name, "").strip()
    return value or default


# Direct, plain-HTTP Vaultwarden 1.37.1 (no proxy).
BASE = _env("VA_E2E_BASE", "http://127.0.0.1:18080")
# Same Vaultwarden instance behind Caddy with mandatory mTLS (mirror of vault-test).
MTLS_BASE = _env("VA_E2E_MTLS_BASE", "https://localhost:18443")
# Direct, plain-HTTP Vaultwarden 1.37.3 (separate database; regression checks).
VW137_BASE = _env("VA_E2E_VW137_BASE", "http://127.0.0.1:18081")

CA_PEM = Path(_env("VA_E2E_CA_PEM", str(PKI_DIR / "ca.pem")))
P12 = Path(_env("VA_E2E_P12", str(PKI_DIR / "client-compat2022.p12")))
P12_PASS = _env("VA_E2E_P12_PASS", "e2e-pass")
# PEM form of the same client identity, for Python `requests` (it cannot read .p12).
CLIENT_CRT = Path(_env("VA_E2E_CLIENT_CRT", str(PKI_DIR / "client.crt")))
CLIENT_KEY = Path(_env("VA_E2E_CLIENT_KEY", str(PKI_DIR / "client.key")))

ADMIN_TOKEN = _env("VA_E2E_ADMIN_TOKEN", "va-e2e-admin-token")

# Fixed base32 TOTP secret (20 bytes) of the TOTP account. Synthetic, test-only.
TOTP_SECRET = _env("VA_E2E_TOTP_SECRET", "VAE2ETOTPSECRETXVAE2ETOTPSECRETX")


@dataclass(frozen=True)
class Account:
    key: str  # short name used on the command line (pbkdf2 / argon / totp)
    email: str
    password: str
    kdf: int  # 0 = PBKDF2-SHA256, 1 = Argon2id
    iterations: int
    memory: int | None = None  # MiB (server units)
    parallelism: int | None = None
    totp_secret: str | None = None


ACCOUNTS: dict[str, Account] = {
    "pbkdf2": Account(
        key="pbkdf2",
        email=_env("VA_E2E_PBKDF2_EMAIL", "pbkdf2@e2e.test"),
        password=_env("VA_E2E_PBKDF2_PASSWORD", "E2e-Pbkdf2-Passw0rd!"),
        kdf=0,
        iterations=600_000,
    ),
    "argon": Account(
        key="argon",
        email=_env("VA_E2E_ARGON_EMAIL", "argon@e2e.test"),
        password=_env("VA_E2E_ARGON_PASSWORD", "E2e-Argon2-Passw0rd!"),
        kdf=1,
        iterations=3,
        memory=64,
        parallelism=4,
    ),
    "totp": Account(
        key="totp",
        email=_env("VA_E2E_TOTP_EMAIL", "totp@e2e.test"),
        password=_env("VA_E2E_TOTP_PASSWORD", "E2e-Totp-Passw0rd!"),
        kdf=0,
        iterations=600_000,
        totp_secret=TOTP_SECRET,
    ),
}


def account(name_or_email: str) -> Account:
    """Look an account up by short name or email (case-insensitive)."""
    wanted = name_or_email.strip().lower()
    for acc in ACCOUNTS.values():
        if wanted in (acc.key, acc.email.lower()):
            return acc
    raise KeyError(f"unknown e2e account {name_or_email!r}; known: {', '.join(ACCOUNTS)}")


def env_lines() -> list[str]:
    """KEY=VALUE lines for the Dart e2e tests (also written to .state/e2e.env)."""
    lines = [
        f"VA_E2E_BASE={BASE}",
        f"VA_E2E_MTLS_BASE={MTLS_BASE}",
        f"VA_E2E_VW137_BASE={VW137_BASE}",
        f"VA_E2E_CA_PEM={CA_PEM}",
        f"VA_E2E_P12={P12}",
        f"VA_E2E_P12_PASS={P12_PASS}",
        f"VA_E2E_CLIENT_CRT={CLIENT_CRT}",
        f"VA_E2E_CLIENT_KEY={CLIENT_KEY}",
        f"VA_E2E_ADMIN_TOKEN={ADMIN_TOKEN}",
        f"VA_E2E_TOTP_SECRET={TOTP_SECRET}",
    ]
    for acc in ACCOUNTS.values():
        prefix = f"VA_E2E_{acc.key.upper()}"
        lines.append(f"{prefix}_EMAIL={acc.email}")
        lines.append(f"{prefix}_PASSWORD={acc.password}")
    return lines


def tls_kwargs(base: str) -> dict:
    """requests.Session settings for a base URL: CA + client cert for the mTLS front."""
    if base.startswith("https://") and base.rstrip("/") == MTLS_BASE.rstrip("/"):
        return {"verify": str(CA_PEM), "cert": (str(CLIENT_CRT), str(CLIENT_KEY))}
    if base.startswith("https://"):
        return {"verify": str(CA_PEM) if CA_PEM.exists() else True, "cert": None}
    return {"verify": True, "cert": None}
