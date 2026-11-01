#!/usr/bin/env bash
# Prints the path of a package that holds only KeyScribeKit and its tests, generating it first.
# SwiftPM links every test target into one bundle, so a plain `swift test` links the whole engine stack
# even for a pure-logic change. This package is the root manifest with every other target filtered out,
# so platforms, pins, and settings cannot drift; repo entries are symlinked so #filePath lookups resolve.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/.build/kit-package"
mkdir -p "$PKG"

for entry in "$ROOT"/* "$ROOT"/.[!.]*; do
  name="$(basename "$entry")"
  case "$name" in Package.swift|.build|.git|.swiftpm) continue ;; esac
  [ -L "$PKG/$name" ] || ln -s "../../$name" "$PKG/$name"
done
for link in "$PKG"/* "$PKG"/.[!.]*; do
  [ -L "$link" ] && [ ! -e "$link" ] && rm "$link"
done

MANIFEST="$(cat "$ROOT/Package.swift"; cat <<'SWIFT'

let kitOnlyTargets: Set<String> = ["KeyScribeKit", "KeyScribeKitTests"]
package.targets.removeAll { !kitOnlyTargets.contains($0.name) }
package.products.removeAll()
SWIFT
)"
if [ ! -f "$PKG/Package.swift" ] || [ "$(cat "$PKG/Package.swift")" != "$MANIFEST" ]; then
  printf '%s\n' "$MANIFEST" > "$PKG/Package.swift"
fi

echo "$PKG"
