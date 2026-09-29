#!/usr/bin/env bash
# Bring the local e2e stack up from scratch (idempotent) and seed the test accounts.
#   tool/e2e/up.sh             venv + PKI (if missing) + containers + accounts
#   tool/e2e/up.sh --selftest  ...and run the harness self-test afterwards
# Env: VA_E2E_PYTHON (python with requirements.txt installed; default tool/e2e/.venv).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${VA_E2E_PYTHON:-$HERE/.venv/bin/python}"

if [ ! -x "$PY" ]; then
  if [ -n "${VA_E2E_PYTHON:-}" ]; then
    echo "up.sh: VA_E2E_PYTHON=$PY is not executable" >&2
    exit 1
  fi
  echo "==> creating $HERE/.venv"
  python3 -m venv "$HERE/.venv"
  "$HERE/.venv/bin/pip" install -q -r "$HERE/requirements.txt"
fi

if [ ! -f "$HERE/.pki/ca.pem" ]; then
  echo "==> generating throwaway PKI"
  PYTHON="$PY" "$HERE/gen-pki.sh"
fi

echo "==> starting containers (project va-e2e)"
docker compose -f "$HERE/compose.yaml" up -d --wait

echo "==> seeding accounts"
"$PY" "$HERE/create_accounts.py"

if [ "${1:-}" = "--selftest" ]; then
  echo "==> self-test"
  "$PY" "$HERE/selftest.py"
fi
