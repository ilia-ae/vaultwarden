#!/bin/sh
# Checks ../../firestore.rules in the Firestore emulator (needs the firebase
# CLI and Java; the emulator is downloaded on first use). Offline-safe: uses
# the demo project, never a real Firebase project.
#
#   sh test/firestore_rules/run.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# The CLI only loads rules from inside its project directory.
cp "$repo/firestore.rules" "$tmp/firestore.rules"
cp "$here/firebase.json" "$tmp/firebase.json"
cd "$tmp"
firebase emulators:exec --project demo-vaultapprover --only firestore \
  "node '$here/rules_test.mjs'"
