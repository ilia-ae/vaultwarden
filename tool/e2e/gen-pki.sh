#!/usr/bin/env bash
# Throwaway PKI for the local VaultApprover e2e stack (tool/e2e/compose.yaml).
#
# Mirrors ~/CODE/vaultwarden-ansible/roles/client_pki: EC P-256 CA (CA:TRUE, pathlen:0,
# keyCertSign+cRLSign, both critical), EC P-256 client certs with CN=<device>, O=<zone>,
# no SAN, keyUsage=digitalSignature (critical), EKU=clientAuth, and the .p12 exported the way
# community.crypto.openssl_pkcs12 does with `encryption_level: compatibility2022`
# (cryptography backend: PBESv1SHA1And3KeyTripleDESCBC for key and certs, HMAC-SHA1 MAC,
# 50000 KDF rounds, friendly name = device name, CA cert included).
#
# Everything lands in tool/e2e/.pki/ (gitignored). Re-running regenerates ALL material
# (restart va-e2e-caddy afterwards so it reloads the server cert and client CA).
#
# Env: OPENSSL (OpenSSL >= 3.4, not LibreSSL), PYTHON (needs `cryptography` >= 38),
#      P12_PASS (default e2e-pass).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/.pki"
P12_PASS="${P12_PASS:-e2e-pass}"

pick_openssl() {
  local c
  for c in "${OPENSSL:-}" openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
    [ -n "$c" ] || continue
    command -v "$c" >/dev/null 2>&1 || continue
    # Need OpenSSL (not LibreSSL) >= 3.4 for -not_before/-not_after and -legacy.
    if "$c" version 2>/dev/null | grep -Eq '^OpenSSL (3\.([4-9]|[1-9][0-9])|[4-9])\.'; then
      echo "$c"
      return 0
    fi
  done
  echo "gen-pki.sh: need OpenSSL >= 3.4 (set OPENSSL=/path/to/openssl)" >&2
  return 1
}
OSSL="$(pick_openssl)"

if [ -z "${PYTHON:-}" ]; then
  for c in "$HERE/.venv/bin/python" python3; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import cryptography' 2>/dev/null; then
      PYTHON="$c"
      break
    fi
  done
fi
if [ -z "${PYTHON:-}" ]; then
  echo "gen-pki.sh: need a python with the 'cryptography' package (set PYTHON=...)" >&2
  exit 1
fi

# UTC timestamps in OpenSSL's [CC]YYMMDDHHMMSSZ form, relative to now (days may be negative).
ts() { "$PYTHON" -c 'import sys,datetime as d; print((d.datetime.now(d.timezone.utc)+d.timedelta(days=float(sys.argv[1]))).strftime("%Y%m%d%H%M%SZ"))' "$1"; }

rm -rf "$OUT"
mkdir -p "$OUT"
chmod 700 "$OUT"
cd "$OUT"

ZONE="e2e.test"

# ---------------------------------------------------------------- CAs
mk_ca() { # name cn
  local name="$1" cn="$2"
  "$OSSL" ecparam -name prime256v1 -genkey -noout -out "$name.key.sec1"
  "$OSSL" pkey -in "$name.key.sec1" -out "$name.key"
  rm -f "$name.key.sec1"
  cat > "$name.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $cn
[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
  "$OSSL" req -new -x509 -key "$name.key" -config "$name.cnf" -extensions v3_ca \
    -sha256 -not_before "$(ts -1)" -not_after "$(ts 3650)" -set_serial "0x$("$OSSL" rand -hex 16)" \
    -out "$name.pem"
  rm -f "$name.cnf"
}
mk_ca ca "va-e2e mTLS CA"
# A second, unrelated CA: certs it signs must be REJECTED by Caddy (negative tests).
mk_ca foreign-ca "va-e2e foreign CA"

# ---------------------------------------------------------------- leaf helper
# mk_leaf <name> <issuer-basename> <not_before_days> <not_after_days> <ext-section-text>
mk_leaf() {
  local name="$1" issuer="$2" nb="$3" na="$4" ext="$5" subj="$6"
  "$OSSL" ecparam -name prime256v1 -genkey -noout -out "$name.key.sec1"
  "$OSSL" pkey -in "$name.key.sec1" -out "$name.key" # PKCS#8
  rm -f "$name.key.sec1"
  "$OSSL" req -new -key "$name.key" -subj "$subj" -out "$name.csr"
  printf '%s\n' "$ext" > "$name.ext"
  "$OSSL" x509 -req -in "$name.csr" -CA "$issuer.pem" -CAkey "$issuer.key" \
    -set_serial "0x$("$OSSL" rand -hex 16)" -sha256 \
    -not_before "$(ts "$nb")" -not_after "$(ts "$na")" \
    -extfile "$name.ext" -out "$name.crt" 2>/dev/null
  rm -f "$name.csr" "$name.ext"
  chmod 600 "$name.key"
}

CLIENT_EXT='basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid'

# Server cert for the Caddy front (https://localhost:18443).
mk_leaf server ca -1 365 'basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost, IP:127.0.0.1, IP:::1
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid' "/CN=localhost"

# Main client cert (730 days like pki_cert_days), plus negative/edge variants.
mk_leaf client ca -1 730 "$CLIENT_EXT" "/CN=va-e2e-client/O=$ZONE"
mk_leaf client-soon ca -1 10 "$CLIENT_EXT" "/CN=va-e2e-client-soon/O=$ZONE"       # expires in 10 days (A14 warning)
mk_leaf client-expired ca -40 -5 "$CLIENT_EXT" "/CN=va-e2e-client-expired/O=$ZONE" # expired 5 days ago (Caddy rejects)
mk_leaf client-foreign foreign-ca -1 730 "$CLIENT_EXT" "/CN=va-e2e-client-foreign/O=$ZONE" # wrong CA (Caddy rejects)

cat client.crt ca.pem > client-chain.pem

# ---------------------------------------------------------------- PKCS#12 variants
# 1) Exactly like community.crypto.openssl_pkcs12 encryption_level=compatibility2022.
p12_compat2022() { # name friendly cert key cafile out
  "$PYTHON" - "$@" "$P12_PASS" <<'PY'
import sys
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.hazmat.primitives.serialization.pkcs12 import PBES

friendly, cert_path, key_path, ca_path, out, password = sys.argv[1:7]
key = serialization.load_pem_private_key(open(key_path, "rb").read(), password=None)
cert = x509.load_pem_x509_certificate(open(cert_path, "rb").read())
ca = x509.load_pem_x509_certificate(open(ca_path, "rb").read())
enc = (
    serialization.PrivateFormat.PKCS12.encryption_builder()
    .kdf_rounds(50000)  # community.crypto default iter_size for compatibility2022
    .key_cert_algorithm(PBES.PBESv1SHA1And3KeyTripleDESCBC)
    .hmac_hash(hashes.SHA1())
    .build(password.encode())
)
data = pkcs12.serialize_key_and_certificates(friendly.encode(), key, cert, [ca], enc)
with open(out, "wb") as f:
    f.write(data)
PY
}

p12_compat2022 va-e2e-client client.crt client.key ca.pem client-compat2022.p12
# 2) OpenSSL 3 defaults: PBES2 (PBKDF2-HMAC-SHA256 + AES-256-CBC), HMAC-SHA256 MAC.
"$OSSL" pkcs12 -export -name va-e2e-client -inkey client.key -in client.crt -certfile ca.pem \
  -passout "pass:$P12_PASS" -out client-openssl3.p12
# 3) OpenSSL -legacy: RC2-40-CBC for certs, 3DES for the key, SHA1 MAC.
"$OSSL" pkcs12 -export -legacy -name va-e2e-client -inkey client.key -in client.crt -certfile ca.pem \
  -passout "pass:$P12_PASS" -out client-legacy.p12

# Edge variants, all in the stand's (compatibility2022) format.
p12_compat2022 va-e2e-client-soon client-soon.crt client-soon.key ca.pem client-soon.p12
p12_compat2022 va-e2e-client-expired client-expired.crt client-expired.key ca.pem client-expired.p12
p12_compat2022 va-e2e-client-foreign client-foreign.crt client-foreign.key foreign-ca.pem client-foreign.p12

# Caddy trusts only ca.pem for client auth.
cp ca.pem client-ca.pem
# Keys stay 0600: the Caddy container runs as root and mounts .pki read-only.
chmod 644 ./*.pem ./*.crt
chmod 600 ./*.key ./*.p12

rm -f foreign-ca.key ./*.srl
echo "PKI written to $OUT:"
ls -1 "$OUT"
