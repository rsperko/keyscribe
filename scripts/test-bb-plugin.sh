#!/usr/bin/env bash
# Runs the bb plugin's behavior tests (Tests/BBPlugin/*.test.ts) with Node's own test runner against
# the exact keyscribe.ts the app packages and installs, under a stubbed bb plugin API. Exits 2 before any
# test when Node is missing or older than the first version that runs TypeScript directly, so an
# incompatible Node is never reported as a test failure. Swift builds and tests never need Node.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MIN_VERSION="22.18.0"
NODE="${NODE:-$(command -v node || true)}"

if [ -z "$NODE" ]; then
  echo "test-bb-plugin: node was not found (set NODE=/path/to/node); connector tests need $MIN_VERSION or later" >&2
  exit 2
fi
VERSION="$("$NODE" --version 2>/dev/null | sed 's/^v//' || true)"
if [ -z "$VERSION" ] || [ "$(printf '%s\n%s\n' "$MIN_VERSION" "$VERSION" | sort -V | head -1)" != "$MIN_VERSION" ]; then
  echo "test-bb-plugin: node ${VERSION:-unknown} is older than the validated $MIN_VERSION" >&2
  exit 2
fi
echo "test-bb-plugin: node $VERSION"

cd "$ROOT"
timeout 300 "$NODE" --test Tests/BBPlugin/*.test.ts
