"""Minimal Bitwarden client protocol + crypto for the VaultApprover e2e harness.

Crypto follows bitwarden/sdk-internal (crates/bitwarden-crypto):
  - keys/kdf.rs          master key: PBKDF2-SHA256(password, lower(trim(email)), N, 32) or
                         Argon2id(password, SHA256(lower(trim(email))), m=MiB*1024 KiB, t, p, 32)
  - keys/master_key.rs   master password hash: PBKDF2-SHA256(masterKey, password, 1, 32), base64
  - keys/utils.rs        stretched master key: HKDF-Expand-SHA256(masterKey, "enc"|"mac", 32)
  - enc_string/          EncString type 2 = AES-256-CBC + HMAC-SHA256 ("2.iv|ct|mac"),
                         type 0 = AES-256-CBC without MAC, type 4/3 = RSA-OAEP-SHA1/-SHA256
  - fingerprint.rs       HKDF-Expand-SHA256(prk=SPKI public key, info=material, 32) -> BigUint
                         -> 5 x (mod 7776) over the EFF long wordlist, joined with "-"
The wordlist is read from lib/utils/eff_wordlist.dart so the harness checks the app's copy.

`python bwproto.py` runs known-answer tests taken from sdk-internal's own unit tests.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import string
import struct
import sys
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import requests
from argon2.low_level import Type as Argon2Type
from argon2.low_level import hash_secret_raw
from cryptography.hazmat.primitives import hashes, padding, serialization
from cryptography.hazmat.primitives.asymmetric import padding as asym_padding
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

import e2e_config as cfg

KDF_PBKDF2 = 0
KDF_ARGON2ID = 1

# Bitwarden DeviceType values (bitwarden/server src/Core/Enums/DeviceType.cs).
DEVICE_ANDROID = 0
DEVICE_IOS = 1
DEVICE_CHROME_EXT = 2
DEVICE_CHROME = 9
DEVICE_FIREFOX = 10
DEVICE_EDGE = 12
DEVICE_SAFARI = 17
DEVICE_UNKNOWN_BROWSER = 14

# Sent as Bitwarden-Client-Version (VW parses it; cloud requires it since 2026-02).
CLIENT_VERSION = os.environ.get("VA_E2E_CLIENT_VERSION", "2026.6.0")


# ─────────────────────────────────────────────────────────────── encoding helpers


def b64e(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def b64d(text: str) -> bytes:
    return base64.b64decode(text)


# ─────────────────────────────────────────────────────────────── KDF / keys


@dataclass(frozen=True)
class Kdf:
    type: int
    iterations: int
    memory: int | None = None  # MiB, as the server stores and returns it
    parallelism: int | None = None

    @staticmethod
    def from_json(data: dict[str, Any]) -> Kdf:
        """Parse /identity/accounts/prelogin or token-response KDF fields (any casing)."""
        lower = {k.lower(): v for k, v in data.items()}

        def pick(*names: str) -> Any:
            for n in names:
                if lower.get(n) is not None:
                    return lower[n]
            return None

        kdf_type = pick("kdf", "kdftype")
        iterations = pick("kdfiterations", "iterations")
        if kdf_type is None or iterations is None:
            raise ValueError(f"no KDF fields in {data!r}")
        return Kdf(
            type=int(kdf_type),
            iterations=int(iterations),
            memory=None if pick("kdfmemory", "memory") is None else int(pick("kdfmemory", "memory")),
            parallelism=None
            if pick("kdfparallelism", "parallelism") is None
            else int(pick("kdfparallelism", "parallelism")),
        )

    def register_fields(self) -> dict[str, Any]:
        return {
            "kdf": self.type,
            "kdfIterations": self.iterations,
            "kdfMemory": self.memory,
            "kdfParallelism": self.parallelism,
        }


def derive_kdf_key(secret: bytes, salt: bytes, kdf: Kdf) -> bytes:
    """sdk-internal keys/kdf.rs KdfDerivedKeyMaterial::derive_kdf_key (same minimums)."""
    if kdf.type == KDF_PBKDF2:
        if kdf.iterations < 5000:
            raise ValueError("insufficient PBKDF2 iterations")
        return hashlib.pbkdf2_hmac("sha256", secret, salt, kdf.iterations, 32)
    if kdf.type == KDF_ARGON2ID:
        if kdf.memory is None or kdf.parallelism is None:
            raise ValueError("Argon2id needs memory and parallelism")
        memory_kib = kdf.memory * 1024  # MiB -> KiB
        if memory_kib < 16 * 1024 or kdf.iterations < 2 or kdf.parallelism < 1:
            raise ValueError("insufficient Argon2id parameters")
        return hash_secret_raw(
            secret=secret,
            salt=hashlib.sha256(salt).digest(),  # full 32-byte SHA-256 of the salt
            time_cost=kdf.iterations,
            memory_cost=memory_kib,
            parallelism=kdf.parallelism,
            hash_len=32,
            type=Argon2Type.ID,
            version=19,
        )
    raise ValueError(f"unknown KDF type {kdf.type}")


def make_master_key(password: str, email: str, kdf: Kdf) -> bytes:
    """Master key; the salt is the trimmed, lower-cased email (KdfDerivedKeyMaterial::derive)."""
    return derive_kdf_key(password.encode("utf-8"), email.strip().lower().encode("utf-8"), kdf)


HASH_SERVER_AUTHORIZATION = 1
HASH_LOCAL_AUTHORIZATION = 2


def master_password_hash(master_key: bytes, password: str, purpose: int = HASH_SERVER_AUTHORIZATION) -> str:
    return b64e(hashlib.pbkdf2_hmac("sha256", master_key, password.encode("utf-8"), purpose, 32))


def hkdf_expand(prk: bytes, info: bytes, length: int) -> bytes:
    """RFC 5869 HKDF-Expand with SHA-256 (PRK used as-is, like hkdf::Hkdf::from_prk)."""
    if len(prk) < 32:
        raise ValueError("PRK shorter than the hash length")
    out, block, counter = b"", b"", 1
    while len(out) < length:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        out += block
        counter += 1
    return out[:length]


@dataclass(frozen=True)
class SymKey:
    enc: bytes
    mac: bytes | None = None

    @staticmethod
    def from_bytes(raw: bytes) -> SymKey:
        if len(raw) == 64:
            return SymKey(raw[:32], raw[32:])
        if len(raw) == 32:
            return SymKey(raw, None)
        raise ValueError(f"unexpected symmetric key length {len(raw)}")

    def to_bytes(self) -> bytes:
        return self.enc + (self.mac or b"")


def stretch_master_key(master_key: bytes) -> SymKey:
    return SymKey(hkdf_expand(master_key, b"enc", 32), hkdf_expand(master_key, b"mac", 32))


# ─────────────────────────────────────────────────────────────── EncString


def _aes_cbc(key: bytes, iv: bytes, data: bytes, encrypt: bool) -> bytes:
    cipher = Cipher(algorithms.AES(key), modes.CBC(iv))
    if encrypt:
        padder = padding.PKCS7(128).padder()
        padded = padder.update(data) + padder.finalize()
        enc = cipher.encryptor()
        return enc.update(padded) + enc.finalize()
    dec = cipher.decryptor()
    padded = dec.update(data) + dec.finalize()
    unpadder = padding.PKCS7(128).unpadder()
    return unpadder.update(padded) + unpadder.finalize()


def enc_string_encrypt(data: bytes, key: SymKey) -> str:
    """EncString type 2 (AesCbc256_HmacSha256_B64): "2.iv|ct|mac"."""
    if key.mac is None:
        raise ValueError("type 2 EncString needs a MAC key")
    iv = os.urandom(16)
    ct = _aes_cbc(key.enc, iv, data, encrypt=True)
    mac = hmac.new(key.mac, iv + ct, hashlib.sha256).digest()
    return f"2.{b64e(iv)}|{b64e(ct)}|{b64e(mac)}"


def enc_string_decrypt(enc: str, key: SymKey) -> bytes:
    """Decrypt EncString types 0 and 2. Type 2 MAC is mandatory and verified."""
    head, _, body = enc.partition(".")
    if not body:
        raise ValueError("EncString without type prefix")
    parts = body.split("|")
    enc_type = int(head)
    if enc_type == 2:
        if len(parts) != 3 or key.mac is None:
            raise ValueError("malformed type 2 EncString or key without MAC")
        iv, ct, mac = (b64d(p) for p in parts)
        expected = hmac.new(key.mac, iv + ct, hashlib.sha256).digest()
        if not hmac.compare_digest(mac, expected):
            raise ValueError("EncString MAC mismatch")
        return _aes_cbc(key.enc, iv, ct, encrypt=False)
    if enc_type == 0:
        if len(parts) != 2:
            raise ValueError("malformed type 0 EncString")
        iv, ct = (b64d(p) for p in parts)
        return _aes_cbc(key.enc, iv, ct, encrypt=False)
    raise ValueError(f"unsupported symmetric EncString type {enc_type}")


def decrypt_user_key(protected_user_key: str, master_key: bytes) -> SymKey:
    """MasterKey::decrypt_user_key: type 2 with the stretched key, legacy type 0 with the raw key."""
    if protected_user_key.startswith("0."):
        return SymKey.from_bytes(enc_string_decrypt(protected_user_key, SymKey(master_key)))
    return SymKey.from_bytes(enc_string_decrypt(protected_user_key, stretch_master_key(master_key)))


# ─────────────────────────────────────────────────────────────── RSA


def generate_rsa_keypair() -> tuple[bytes, bytes]:
    """Returns (PKCS#8 DER private key, SPKI DER public key), RSA-2048 e=65537."""
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pkcs8 = private.private_bytes(
        serialization.Encoding.DER, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    )
    return pkcs8, spki_from_private(pkcs8)


def spki_from_private(pkcs8_der: bytes) -> bytes:
    private = serialization.load_der_private_key(pkcs8_der, password=None)
    return private.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )


def _oaep(enc_type: int) -> asym_padding.OAEP:
    algo = {3: hashes.SHA256(), 4: hashes.SHA1()}.get(enc_type)  # noqa: S303 - protocol-mandated
    if algo is None:
        raise ValueError(f"unsupported asymmetric EncString type {enc_type}")
    return asym_padding.OAEP(mgf=asym_padding.MGF1(algorithm=algo), algorithm=algo, label=None)


def rsa_encrypt(spki_der: bytes, data: bytes, enc_type: int = 4) -> str:
    """Asymmetric EncString; type 4 = Rsa2048_OaepSha1_B64 (what VaultApprover sends)."""
    public = serialization.load_der_public_key(spki_der)
    return f"{enc_type}.{b64e(public.encrypt(data, _oaep(enc_type)))}"


def rsa_decrypt(pkcs8_der: bytes, enc: str) -> bytes:
    head, _, body = enc.partition(".")
    enc_type = int(head)
    private = serialization.load_der_private_key(pkcs8_der, password=None)
    return private.decrypt(b64d(body.split("|")[0]), _oaep(enc_type))


# ─────────────────────────────────────────────────────────────── fingerprint phrase

_WORDLIST: list[str] | None = None


def eff_wordlist() -> list[str]:
    """The EFF long wordlist exactly as the app ships it (lib/utils/eff_wordlist.dart)."""
    global _WORDLIST
    if _WORDLIST is None:
        text = cfg.WORDLIST_DART.read_text(encoding="utf-8")
        body = text[text.index("[") : text.rindex("]")]
        words = re.findall(r"'([^']*)'", body)
        if len(words) != 7776:
            raise ValueError(f"{cfg.WORDLIST_DART}: expected 7776 words, found {len(words)}")
        _WORDLIST = words
    return _WORDLIST


def fingerprint(material: str, spki_der: bytes) -> str:
    """sdk-internal fingerprint.rs `fingerprint()` (5 words, '-' separated)."""
    words = eff_wordlist()
    digest = hkdf_expand(spki_der, material.encode("utf-8"), 32)
    number = int.from_bytes(digest, "big")
    phrase = []
    for _ in range(5):  # ceil(64 / log2(7776)) = 5
        number, index = divmod(number, len(words))
        phrase.append(words[index])
    return "-".join(phrase)


def auth_request_fingerprint(email: str, spki_der: bytes) -> str:
    """Phrase shown for an auth request: clients use email.toLowerCase() as the material."""
    return fingerprint(email.lower(), spki_der)


# ─────────────────────────────────────────────────────────────── TOTP


def totp(secret_b32: str, step: int | None = None, digits: int = 6) -> str:
    """RFC 6238 TOTP (HMAC-SHA1, 30 s) for an explicit time step (default: now)."""
    if step is None:
        step = int(time.time() // 30)
    key = base64.b32decode(secret_b32.upper() + "=" * (-len(secret_b32) % 8))
    mac = hmac.new(key, struct.pack(">Q", step), hashlib.sha1).digest()
    offset = mac[-1] & 0x0F
    code = (struct.unpack(">I", mac[offset : offset + 4])[0] & 0x7FFFFFFF) % (10**digits)
    return str(code).zfill(digits)


def access_code(length: int = 25) -> str:
    """Like the web client's auth-request access code (password generator, 25 chars)."""
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


# ─────────────────────────────────────────────────────────────── persistent harness state


class State:
    """Small JSON store in tool/e2e/.state/state.json (device ids, remember tokens)."""

    def __init__(self, path: Path | None = None):
        self.path = path or (cfg.STATE_DIR / "state.json")

    def _load(self) -> dict[str, Any]:
        try:
            return json.loads(self.path.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def get(self, key: str) -> dict[str, Any]:
        return dict(self._load().get(key, {}))

    def put(self, key: str, value: dict[str, Any]) -> None:
        data = self._load()
        data[key] = value
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=2, sort_keys=True))
        tmp.replace(self.path)


def state_key(base: str, email: str, role: str) -> str:
    return f"{base.rstrip('/')}|{email.lower()}|{role}"


# ─────────────────────────────────────────────────────────────── HTTP client


class ApiError(Exception):
    def __init__(self, status: int, message: str, body: Any):
        super().__init__(f"HTTP {status}: {message}")
        self.status = status
        self.message = message
        self.body = body


class TwoFactorRequired(ApiError):
    def __init__(self, status: int, body: dict[str, Any]):
        providers = body.get("TwoFactorProviders") or list((body.get("TwoFactorProviders2") or {}).keys())
        self.providers = [int(p) for p in providers]
        super().__init__(status, "Two factor required", body)


def error_message(body: Any) -> str:
    if isinstance(body, dict):
        for path in (("error_description",), ("ErrorModel", "Message"), ("errorModel", "message"), ("message",)):
            node: Any = body
            for part in path:
                node = node.get(part) if isinstance(node, dict) else None
            if node:
                return str(node)
        if body.get("error"):
            return str(body["error"])
    return str(body)[:300]


@dataclass
class Device:
    identifier: str
    type: int
    name: str


@dataclass
class LoginResult:
    token: dict[str, Any]
    access_token: str
    refresh_token: str | None
    user_key: SymKey | None = None
    private_key: bytes | None = None
    extra: dict[str, Any] = field(default_factory=dict)


class BwClient:
    def __init__(
        self,
        base: str,
        device: Device,
        *,
        client_id: str = "web",
        client_ip: str | None = None,
        timeout: float = 20.0,
    ):
        self.base = base.rstrip("/")
        self.device = device
        self.client_id = client_id
        self.timeout = timeout
        self.http = requests.Session()
        tls = cfg.tls_kwargs(self.base)
        self.http.verify = tls["verify"]
        if tls["cert"]:
            self.http.cert = tls["cert"]
        self.http.headers.update(
            {
                "Accept": "application/json",
                "Device-Type": str(device.type),
                "Bitwarden-Client-Name": client_id,
                "Bitwarden-Client-Version": CLIENT_VERSION,
            }
        )
        if client_ip:
            # Honoured on the direct ports only (IP_HEADER=X-Real-IP from private sources);
            # Caddy overwrites it with the real peer address on the mTLS front.
            self.http.headers["X-Real-IP"] = client_ip
        self.access_token: str | None = None

    # -- raw ---------------------------------------------------------------

    def request(self, method: str, path: str, *, auth: bool = True, **kwargs: Any) -> Any:
        headers = dict(kwargs.pop("headers", {}) or {})
        if auth:
            if not self.access_token:
                raise RuntimeError("not logged in")
            headers["Authorization"] = f"Bearer {self.access_token}"
        resp = self.http.request(method, self.base + path, headers=headers, timeout=self.timeout, **kwargs)
        try:
            body = resp.json() if resp.content else None
        except ValueError:
            body = resp.text
        if resp.status_code >= 400:
            if isinstance(body, dict) and (body.get("TwoFactorProviders") or body.get("TwoFactorProviders2")):
                raise TwoFactorRequired(resp.status_code, body)
            raise ApiError(resp.status_code, error_message(body), body)
        return body

    # -- identity ------------------------------------------------------------

    def prelogin(self, email: str) -> Kdf:
        return Kdf.from_json(self.request("POST", "/identity/accounts/prelogin", auth=False, json={"email": email}))

    def register(self, email: str, password: str, kdf: Kdf, name: str | None = None) -> dict[str, Any]:
        """Create an account the way the web vault's legacy register call does."""
        master_key = make_master_key(password, email, kdf)
        user_key = SymKey.from_bytes(os.urandom(64))
        pkcs8, spki = generate_rsa_keypair()
        body = {
            "email": email,
            "name": name or email.split("@")[0],
            "masterPasswordHash": master_password_hash(master_key, password),
            "masterPasswordHint": None,
            "key": enc_string_encrypt(user_key.to_bytes(), stretch_master_key(master_key)),
            "keys": {"publicKey": b64e(spki), "encryptedPrivateKey": enc_string_encrypt(pkcs8, user_key)},
            **kdf.register_fields(),
        }
        return self.request("POST", "/identity/accounts/register", auth=False, json=body)

    def token(self, form: dict[str, str]) -> dict[str, Any]:
        base_form = {
            "scope": "api offline_access",
            "client_id": self.client_id,
            "deviceType": str(self.device.type),
            "deviceIdentifier": self.device.identifier,
            "deviceName": self.device.name,
        }
        base_form.update(form)
        result = self.request(
            "POST",
            "/identity/connect/token",
            auth=False,
            data=base_form,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        self.access_token = result["access_token"]
        return result

    def login(
        self,
        email: str,
        secret: str,
        *,
        auth_request_id: str | None = None,
        totp_secret: str | None = None,
        state: State | None = None,
        state_role: str | None = None,
    ) -> dict[str, Any]:
        """Password grant with 2FA handling (remember token first, then TOTP).

        `secret` is the master password hash, or the access code when `auth_request_id` is set.
        Remember tokens are kept per (base, email, role) in `state`.
        """
        form = {"grant_type": "password", "username": email, "password": secret}
        if auth_request_id:
            form["authRequest"] = auth_request_id
        skey = state_key(self.base, email, state_role) if state and state_role else None
        remembered = state.get(skey).get("remember") if (state and skey) else None
        if remembered and state and skey:
            st = state.get(skey)
            if st.get("device_id") != self.device.identifier:
                remembered = None

        def done(result: dict[str, Any]) -> dict[str, Any]:
            if state and skey and result.get("TwoFactorToken"):
                st = state.get(skey)
                st["remember"] = result["TwoFactorToken"]
                st["device_id"] = self.device.identifier
                state.put(skey, st)
            return result

        if remembered:
            try:
                return done(
                    self.token({**form, "twoFactorProvider": "5", "twoFactorToken": remembered, "twoFactorRemember": "1"})
                )
            except TwoFactorRequired:
                pass  # token revoked/expired; the server already dropped it
        try:
            return done(self.token(form))
        except TwoFactorRequired as tfr:
            if 0 not in tfr.providers or not totp_secret:
                raise
        tried: set[int] = set()
        last_error: Exception | None = None
        for _ in range(6):
            now_step = int(time.time() // 30)
            candidates = [s for s in (now_step, now_step + 1) if s not in tried and s >= max(tried, default=0)]
            if not candidates:
                time.sleep((now_step + 1) * 30 - time.time() + 0.5)
                continue
            step = candidates[0]
            tried.add(step)
            try:
                return done(
                    self.token(
                        {
                            **form,
                            "twoFactorProvider": "0",
                            "twoFactorToken": totp(totp_secret, step),
                            "twoFactorRemember": "1",
                        }
                    )
                )
            except ApiError as err:
                # A TOTP step can be used once per user (VW stores last_used): move forward.
                if "totp" not in err.message.lower():
                    raise
                last_error = err
        raise last_error or RuntimeError("TOTP login failed")

    def login_password(
        self,
        email: str,
        password: str,
        *,
        totp_secret: str | None = None,
        state: State | None = None,
        state_role: str | None = None,
    ) -> LoginResult:
        """Full master-password login: prelogin -> KDF -> token -> user key -> private key."""
        kdf = self.prelogin(email)
        master_key = make_master_key(password, email, kdf)
        token = self.login(
            email,
            master_password_hash(master_key, password),
            totp_secret=totp_secret,
            state=state,
            state_role=state_role,
        )
        protected = token.get("Key") or token.get("key")
        if not protected:
            unlock = (token.get("UserDecryptionOptions") or {}).get("MasterPasswordUnlock") or {}
            protected = unlock.get("MasterKeyEncryptedUserKey")
        if not protected:
            raise RuntimeError("token response has no Key / MasterPasswordUnlock")
        user_key = decrypt_user_key(protected, master_key)
        private_key = None
        if token.get("PrivateKey"):
            private_key = enc_string_decrypt(token["PrivateKey"], user_key)
        return LoginResult(
            token=token,
            access_token=token["access_token"],
            refresh_token=token.get("refresh_token"),
            user_key=user_key,
            private_key=private_key,
            extra={"kdf": kdf, "master_key": master_key},
        )


def new_device(state: State, base: str, email: str, role: str, dev_type: int, name: str) -> tuple[Device, dict]:
    """Stable per-(base, email, role) device identity, persisted in .state/state.json."""
    key = state_key(base, email, role)
    st = state.get(key)
    if not st.get("device_id") or st.get("device_type") != dev_type:
        st = {"device_id": str(uuid.uuid4()), "device_type": dev_type}
        state.put(key, st)
    return Device(identifier=st["device_id"], type=dev_type, name=name), st


# ─────────────────────────────────────────────────────────────── self-test (KATs)


def _selftest() -> None:
    # keys/master_key.rs test_password_hash_pbkdf2 (email is trimmed + lower-cased)
    for salt in ("test@bitwarden.com", "TEST@bitwarden.com", " test@bitwarden.com"):
        mk = make_master_key("asdfasdf", salt, Kdf(KDF_PBKDF2, 100_000))
        assert master_password_hash(mk, "asdfasdf") == "wmyadRMyBZOH7P/a/ucTCbSghKgdzDpPqUnu/DAVtSw=", salt
    # keys/master_key.rs test_password_hash_argon2id (salt = SHA-256("test_salt"), 32 MiB)
    mk = make_master_key("asdfasdf", "test_salt", Kdf(KDF_ARGON2ID, 4, 32, 2))
    assert master_password_hash(mk, "asdfasdf") == "PR6UjYmjmppTYcdyTiNbAhPJuQQOmynKbdEl1oyi/iQ="
    # keys/master_key.rs test_decrypt_user_key_aes_cbc256_b64 (legacy type 0 user key)
    mk = make_master_key("asdfasdfasdf", "legacy@bitwarden.com", Kdf(KDF_PBKDF2, 600_000))
    uk = decrypt_user_key(
        "0.8UClLa8IPE1iZT7chy5wzQ==|6PVfHnVk5S3XqEtQemnM5yb4JodxmPkkWzmDRdfyHtjORmvxqlLX40tBJZ+CKxQWm"
        "S8tpEB5w39rbgHg/gqs0haGdZG4cPbywsgGzxZ7uNI=",
        mk,
    )
    assert list(uk.enc[:4]) == [12, 95, 151, 203] and list(uk.mac[-4:]) == [128, 224, 140, 167]
    # fingerprint.rs test_fingerprint
    key = bytes(
        [48, 130, 1, 34, 48, 13, 6, 9, 42, 134, 72, 134, 247, 13, 1, 1, 1, 5, 0, 3, 130, 1, 15, 0, 48, 130, 1, 10, 2,
         130, 1, 1, 0, 187, 38, 44, 241, 110, 205, 89, 253, 25, 191, 126, 84, 121, 202, 61, 223, 189, 244, 118, 212,
         74, 139, 130, 97, 115, 164, 167, 106, 191, 188, 233, 218, 196, 250, 187, 146, 125, 160, 150, 49, 198, 224,
         176, 10, 0, 143, 99, 230, 232, 160, 51, 104, 154, 211, 33, 80, 170, 4, 68, 80, 219, 115, 167, 114, 156, 227,
         125, 193, 128, 123, 39, 254, 191, 124, 63, 129, 44, 63, 18, 56, 161, 48, 158, 0, 27, 146, 2, 99, 136, 75, 21,
         135, 6, 118, 12, 26, 251, 184, 172, 249, 53, 78, 210, 46, 143, 17, 104, 202, 65, 173, 229, 219, 233, 144,
         163, 101, 216, 238, 152, 54, 158, 1, 195, 50, 203, 21, 226, 12, 82, 170, 175, 170, 160, 21, 247, 248, 80, 97,
         123, 0, 152, 116, 229, 126, 221, 199, 155, 194, 192, 51, 207, 177, 240, 160, 84, 241, 41, 88, 176, 53, 111,
         28, 173, 177, 232, 158, 22, 79, 133, 152, 31, 32, 12, 196, 147, 58, 57, 50, 252, 208, 131, 150, 179, 132,
         178, 150, 234, 251, 143, 125, 163, 144, 20, 46, 71, 168, 252, 164, 86, 120, 124, 56, 252, 206, 210, 236, 212,
         139, 127, 189, 236, 40, 46, 2, 238, 13, 216, 40, 48, 85, 133, 229, 181, 155, 176, 217, 241, 154, 153, 213,
         112, 222, 72, 219, 197, 3, 219, 56, 77, 109, 47, 72, 251, 131, 36, 240, 96, 169, 31, 82, 93, 166, 242, 3, 33,
         213, 2, 3, 1, 0, 1]
    )  # fmt: skip
    assert fingerprint("a09726a0-9590-49d1-a5f5-afe300b6a515", key) == "turban-deftly-anime-chatroom-unselfish"
    # RFC 6238 appendix B (SHA-1 seed "12345678901234567890", T=59 -> 94287082, 8 digits)
    assert totp(base64.b32encode(b"12345678901234567890").decode(), 59 // 30, digits=8) == "94287082"
    # round trips
    k = SymKey.from_bytes(os.urandom(64))
    assert enc_string_decrypt(enc_string_encrypt(b"hello", k), k) == b"hello"
    pkcs8, spki = generate_rsa_keypair()
    assert rsa_decrypt(pkcs8, rsa_encrypt(spki, b"x" * 64)) == b"x" * 64
    print("bwproto self-test OK (sdk-internal KATs: PBKDF2, Argon2id, legacy user key, fingerprint; RFC 6238)")


if __name__ == "__main__":
    _selftest()
    sys.exit(0)
