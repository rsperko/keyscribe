#!/usr/bin/env bash
# Type-checks the bb plugin the app installs (server.ts, app.tsx, keyscribe.ts) against bb's published plugin SDK.
# With no argument it uses the SDK version the plugin's package.json pins; pass a version or "latest" to check
# against another. Installs the SDK into a scratch folder from npm, so it needs network access.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$ROOT/Sources/KeyScribe/Resources/BBPlugin"
NPM="${NPM:-$(command -v npm || true)}"
if [ -z "$NPM" ]; then
  echo "check-bb-plugin-sdk: npm was not found (set NPM=/path/to/npm)" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ks-bb-sdk.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cp "$PLUGIN/package.json" "$PLUGIN/server.ts" "$PLUGIN/app.tsx" "$PLUGIN/keyscribe.ts" "$WORK/"
cd "$WORK"
timeout 300 "$NPM" install --no-audit --no-fund --ignore-scripts --silent >install.log 2>&1 || { cat install.log >&2; exit 1; }
if [ -n "${1:-}" ]; then
  timeout 300 "$NPM" install --no-audit --no-fund --ignore-scripts --silent "@get-bb/plugin-sdk@$1" >>install.log 2>&1 || { cat install.log >&2; exit 1; }
fi
cat > tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "target": "ESNext", "module": "ESNext", "moduleResolution": "bundler", "jsx": "react-jsx", "strict": true,
    "noEmit": true, "skipLibCheck": true, "allowImportingTsExtensions": true, "lib": ["ESNext", "DOM"], "types": ["node"]
  },
  "include": ["server.ts", "app.tsx", "keyscribe.ts"]
}
EOF
SDK="$(node -p "require('./node_modules/@get-bb/plugin-sdk/package.json').version")"
timeout 120 node_modules/.bin/tsc -p .
echo "check-bb-plugin-sdk: the plugin type-checks against @get-bb/plugin-sdk $SDK"
