#!/usr/bin/env bash
# Runs the Claude Code connector's behavior tests (Tests/ClaudeConnector/*.test.ts) with the Claude Code
# CLI's own mod test runner, against the register.js the app packages, with the environment reader installed
# the way the app installs it, for the variables the tests use. Exits 2 before
# any test when the CLI is missing, older than the validated minimum, or has no test runner, so an
# incompatible CLI is never reported as a test failure. Swift builds and tests never need the CLI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MIN_VERSION="2.1.316"
CLAUDE="${CLAUDE:-$(command -v claude || true)}"

if [ -z "$CLAUDE" ]; then
  echo "test-claude-connector: the claude CLI was not found (set CLAUDE=/path/to/claude); connector tests need $MIN_VERSION or later" >&2
  exit 2
fi
VERSION="$("$CLAUDE" --version 2>/dev/null | awk '{print $1}')"
if [ -z "$VERSION" ] || [ "$(printf '%s\n%s\n' "$MIN_VERSION" "$VERSION" | sort -V | head -1)" != "$MIN_VERSION" ]; then
  echo "test-claude-connector: claude ${VERSION:-unknown} is older than the validated $MIN_VERSION" >&2
  exit 2
fi
if ! "$CLAUDE" plugin test --help 2>/dev/null | grep -q "claude-code/testing"; then
  echo "test-claude-connector: claude $VERSION has no 'plugin test' runner" >&2
  exit 2
fi
echo "test-claude-connector: claude $VERSION"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ks-connector-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PLUGIN="$WORK/plugin"
mkdir -p "$PLUGIN/.claude-plugin" "$PLUGIN/hooks" "$PLUGIN/tests" "$WORK/config"
printf '{"name":"keyscribe-connector-test","version":"0.0.0"}\n' > "$PLUGIN/.claude-plugin/plugin.json"
printf '{"modules":["./register.js"]}\n' > "$PLUGIN/hooks/hooks.json"
"$ROOT/scripts/claude-connector-env-reader.sh" CMUX_SURFACE_ID MUX_PANE TMUX ZELLIJ_PANE_ID > "$WORK/reader.js"
awk -v reader="$WORK/reader.js" '
  /^async function readEnvironment\(\$\) \{$/ { while ((getline line < reader) > 0) print line; skipping = 1; next }
  skipping && /^}$/ { skipping = 0; next }
  !skipping
' "$ROOT/Sources/KeyScribe/Resources/ClaudeConnector/register.js" > "$PLUGIN/hooks/register.js"
grep -q '$.env.get("MUX_PANE")' "$PLUGIN/hooks/register.js" || {
  echo "test-claude-connector: could not install the environment reader into register.js" >&2
  exit 1
}
cp "$ROOT"/Tests/ClaudeConnector/*.test.ts "$PLUGIN/tests/"

CLAUDE_CONFIG_DIR="$WORK/config" timeout 300 "$CLAUDE" plugin validate "$PLUGIN" >"$WORK/validate.log" 2>&1 || {
  cat "$WORK/validate.log" >&2
  exit 1
}
cd "$PLUGIN"
CLAUDE_CONFIG_DIR="$WORK/config" timeout 300 "$CLAUDE" plugin test .
