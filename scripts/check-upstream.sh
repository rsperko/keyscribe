#!/usr/bin/env bash
# Checks the agent extensions against the hosts' latest upstream: moves a cached Ultimate checkout to the newest
# main of ULTIMATE_REPO, installs it and runs the Ultimate connector tests with its own extension checker and the
# headless page smoke check, then
# type-checks the bb plugin against bb's latest published SDK. Prints the Ultimate commit and the bb SDK version it
# checked. Needs network access, git, npm, and for Ultimate a Node that its package.json accepts (ULTIMATE_NODE)
# with pnpm beside it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${ULTIMATE_REPO:-https://github.com/HazAT/ultimate.git}"
CACHE="${KEYSCRIBE_UPSTREAM_DIR:-$HOME/Library/Caches/KeyScribe/upstream}"
CLONE="$CACHE/ultimate"
ULTIMATE_NODE="${ULTIMATE_NODE:-$(command -v node || true)}"
if [ -z "$ULTIMATE_NODE" ] || [ ! -x "$(dirname "$ULTIMATE_NODE")/pnpm" ]; then
  echo "check-upstream: set ULTIMATE_NODE to a Node that has pnpm beside it" >&2
  exit 2
fi

mkdir -p "$CACHE"
if [ ! -d "$CLONE/.git" ]; then
  timeout 300 git clone --quiet "$REPO" "$CLONE"
fi
timeout 300 git -C "$CLONE" fetch --quiet origin main
git -C "$CLONE" checkout --quiet --detach --force origin/main
git -C "$CLONE" clean --quiet -fdx -e node_modules
(cd "$CLONE" && PATH="$(dirname "$ULTIMATE_NODE"):$PATH" timeout 600 pnpm install --frozen-lockfile --silent)
echo "check-upstream: Ultimate $(git -C "$CLONE" log -1 --format='%h %cs %s')"

ULTIMATE_CLONE="$CLONE" ULTIMATE_NODE="$ULTIMATE_NODE" "$ROOT/scripts/test-ultimate-connector.sh"
ULTIMATE_CLONE="$CLONE" timeout 400 "$ULTIMATE_NODE" "$ROOT/Tests/UltimateConnector/e2e/page-smoke.ts"
"$ROOT/scripts/check-bb-plugin-sdk.sh" latest
