#!/usr/bin/env bash
# Runs the Ultimate connector's behavior tests (Tests/UltimateConnector/*.test.ts) with Node's own test runner against
# the exact keyscribe.ts the app packages and installs, under a stubbed Ultimate. Exits 2 before any
# test when Node is missing or older than the first version that runs TypeScript directly, so an
# incompatible Node is never reported as a test failure. Swift builds and tests never need Node.
# With ULTIMATE_CLONE set, Ultimate's own scripts/check-extension.ts also checks the extension against that
# checkout's SDK.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

CLONE="${ULTIMATE_CLONE:-}"
if [ -n "$CLONE" ]; then
  CHECKER="$CLONE/scripts/check-extension.ts"
  if [ ! -d "$CLONE/node_modules" ] || ! grep -qF "web.solid.tsx" "$CHECKER" 2>/dev/null; then
    echo "test-ultimate-connector: $CLONE is not an installed Ultimate 0.1 or later; its scripts/check-extension.ts must check web.solid.tsx" >&2
    exit 1
  fi
  echo "test-ultimate-connector: checking the extension with $CLONE at $(git -C "$CLONE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi

MIN_VERSION="22.18.0"
NODE="${NODE:-$(command -v node || true)}"

if [ -z "$NODE" ]; then
  echo "test-ultimate-connector: node was not found (set NODE=/path/to/node); connector tests need $MIN_VERSION or later" >&2
  exit 2
fi
VERSION="$("$NODE" --version 2>/dev/null | sed 's/^v//' || true)"
if [ -z "$VERSION" ] || [ "$(printf '%s\n%s\n' "$MIN_VERSION" "$VERSION" | sort -V | head -1)" != "$MIN_VERSION" ]; then
  echo "test-ultimate-connector: node ${VERSION:-unknown} is older than the validated $MIN_VERSION" >&2
  exit 2
fi
echo "test-ultimate-connector: node $VERSION"


cd "$ROOT"
timeout 300 "$NODE" --test Tests/UltimateConnector/*.test.ts Tests/AgentConformance/*.test.ts

if [ -n "$CLONE" ]; then
  CHECK="$(mktemp -d "${TMPDIR:-/tmp}/ks-ultimate-check.XXXXXX")"
  trap 'rm -rf "$CHECK"' EXIT
  mkdir "$CHECK/keyscribe"
  cp "$ROOT"/Sources/KeyScribe/Resources/UltimateConnector/* "$CHECK/keyscribe/"
  (cd "$CLONE" && timeout 180 "${ULTIMATE_NODE:-$NODE}" scripts/check-extension.ts "$CHECK/keyscribe")
fi
