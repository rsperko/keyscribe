#!/usr/bin/env bash
# Runs one agent's extension connector behavior tests (Tests/<Agent>Connector/*.test.ts, agent pi or omp) with
# Node's own test runner against the exact index.ts the app packages and installs, under that agent's stubbed
# extension API. Exits 2 before any test when Node is missing or older than the first version that runs
# TypeScript directly, so an incompatible Node is never reported as a test failure. Swift builds and tests never
# need Node.
set -euo pipefail

case "${1:-}" in
  pi) SUITE="Tests/PiConnector" ;;
  omp) SUITE="Tests/OmpConnector" ;;
  *) echo "usage: $0 pi|omp" >&2; exit 64 ;;
esac
NAME="test-$1-connector"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MIN_VERSION="22.18.0"
NODE="${NODE:-$(command -v node || true)}"

if [ -z "$NODE" ]; then
  echo "$NAME: node was not found (set NODE=/path/to/node); connector tests need $MIN_VERSION or later" >&2
  exit 2
fi
VERSION="$("$NODE" --version 2>/dev/null | sed 's/^v//' || true)"
if [ -z "$VERSION" ] || [ "$(printf '%s\n%s\n' "$MIN_VERSION" "$VERSION" | sort -V | head -1)" != "$MIN_VERSION" ]; then
  echo "$NAME: node ${VERSION:-unknown} is older than the validated $MIN_VERSION" >&2
  exit 2
fi
echo "$NAME: node $VERSION"

cd "$ROOT"
timeout 300 "$NODE" --test "$SUITE"/*.test.ts
