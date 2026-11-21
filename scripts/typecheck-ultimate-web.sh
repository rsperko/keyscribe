#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLONE="$1"
SOURCES="${2:-$ROOT/Sources/KeyScribe/Resources/UltimateConnector}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp "$SOURCES/web.tsx" "$tmp/web.tsx"
cp "$SOURCES/keyscribe.ts" "$tmp/keyscribe.ts"
ln -s "$CLONE/node_modules" "$tmp/node_modules"
cat > "$tmp/tsconfig.json" <<EOF
{
  "compilerOptions": {
    "target": "ESNext",
    "lib": ["ESNext", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "moduleResolution": "bundler",
    "jsx": "react-jsx",
    "strict": true,
    "noEmit": true,
    "skipLibCheck": true,
    "allowImportingTsExtensions": true,
    "paths": {
      "@/*": ["$CLONE/web/src/*"]
    },
    "typeRoots": ["$CLONE/node_modules/@types"]
  },
  "include": ["web.tsx"]
}
EOF
log="$tmp/tsc.log"
status=0
(cd "$tmp" && timeout 60 "$CLONE/node_modules/.bin/tsc" -p tsconfig.json --noEmit) >"$log" 2>&1 || status=$?
errors="$(grep "error TS" "$log" || true)"
elsewhere="$(printf '%s\n' "$errors" | grep -E '^(\.\./|/).*\([0-9]+,[0-9]+\): error TS' || true)"
if [ "$status" = 0 ]; then
  echo "typecheck-ultimate-web: ok ($CLONE)"
elif [ "$status" = 124 ]; then
  echo "typecheck-ultimate-web: tsc timed out ($CLONE)" >&2
  exit 1
elif { [ "$status" = 1 ] || [ "$status" = 2 ]; } && [ -n "$errors" ] && [ "$errors" = "$elsewhere" ]; then
  echo "typecheck-ultimate-web: ok; errors only in $CLONE"
else
  cat "$log" >&2
  exit 1
fi
