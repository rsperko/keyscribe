#!/usr/bin/env bash
# Build MLX's Metal shader library and place it beside the SwiftPM executable output
# (.build/<config>/mlx.metallib), where MLX's colocated lookup finds it first.
#
# Why this script exists: SwiftPM's *native* build system does not compile .metal sources, so
# `swift build` produces no metallib and Qwen3-ASR dies at its first GPU op ("Failed to load the
# default metallib"). Xcode's build engine does compile them — which is why a downstream Xcode
# build needs none of this. See BUILD.md.
#
# Why only these sources: mlx-swift pins the ahead-of-time kernel set in
# Source/Cmlx/mlx-generated/metal — exactly what its Xcode build compiles into default.metallib.
# Every other kernel is generated at runtime, because the SwiftPM build enables MLX's JIT
# (Package.swift excludes nojit_kernels.cpp), and each one has a matching generator under
# mlx-generated/*.cpp. Compiling the whole backend/metal/kernels tree instead produced a 107 MB
# metallib — 15,005 shader functions against the 385 actually needed, and half the shipped .app —
# with byte-identical transcription. Do NOT "fix" this back to a glob of the kernels directory.
#
# fence.metal is the one addition: MLX's own CMake builds it for Metal >= 3.2 but mlx-swift's
# generated set omits it, so it is compiled here from the kernels tree (it has no includes) to
# keep fence_wait available. Reachable only under MLX_METAL_FAST_SYNCH; cheap insurance.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-mlx-metallib.sh [debug|release] [--force]

Builds mlx.metallib into .build/<config>/. Skips the build when the shader sources are unchanged.

If you see "missing Metal Toolchain", run:
  xcodebuild -downloadComponent MetalToolchain
EOF
}

CONFIG="release"
FORCE=0
for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG="$arg" ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/.build}"
MLX_DIR="$BUILD_DIR/checkouts/mlx-swift/Source/Cmlx"
GENERATED_METAL="$MLX_DIR/mlx-generated/metal"
FENCE="$MLX_DIR/mlx/mlx/backend/metal/kernels/fence.metal"

if [[ ! -d "$GENERATED_METAL" ]]; then
  echo "error: mlx-swift shader sources not found at $GENERATED_METAL" >&2
  echo "hint: run 'swift build' first so SwiftPM resolves the checkout" >&2
  exit 1
fi

OUT_DIR="$BUILD_DIR/$CONFIG"
[[ -d "$OUT_DIR" ]] || OUT_DIR="$(find "$BUILD_DIR" -maxdepth 3 -type d -path "*/$CONFIG" | head -n 1 || true)"
if [[ -z "${OUT_DIR:-}" || ! -d "$OUT_DIR" ]]; then
  echo "error: no SwiftPM output directory for config=$CONFIG under $BUILD_DIR (run 'swift build' first)" >&2
  exit 1
fi

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done \
  < <(find "$GENERATED_METAL" -type f -name '*.metal' | LC_ALL=C sort)
[[ -f "$FENCE" ]] && SOURCES+=("$FENCE")
if [[ "${#SOURCES[@]}" -eq 0 ]]; then
  echo "error: no .metal sources found under $GENERATED_METAL" >&2
  exit 1
fi

OUT_METALLIB="$OUT_DIR/mlx.metallib"
HASH_FILE="$OUT_DIR/.mlx.metallib.sha"
CURRENT_HASH="$(
  { find "$GENERATED_METAL" -type f \( -name '*.metal' -o -name '*.h' \) | LC_ALL=C sort; echo "$FENCE"; } \
    | xargs cat | shasum -a 256 | awk '{print $1}'
)"

if [[ "$FORCE" != "1" && -f "$OUT_METALLIB" && -f "$HASH_FILE" ]] \
  && [[ "$CURRENT_HASH" == "$(cat "$HASH_FILE" 2>/dev/null || true)" ]]; then
  echo "mlx.metallib is up to date — skipping ($(basename "$OUT_METALLIB"))"
  exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mlx-metallib.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Flags match MLX's own CMake METAL_FLAGS and mlx-swift's MTL_COMPILER_FLAGS — keep them in sync.
METAL_FLAGS=(-x metal -Wall -Wextra -fno-fast-math -Wno-c++17-extensions -Wno-c++20-extensions)

echo "== compiling ${#SOURCES[@]} Metal sources =="
AIR_FILES=()
for src in "${SOURCES[@]}"; do
  air="$TMP/$(printf '%s' "$src" | shasum -a 256 | cut -c1-16).air"
  if ! xcrun -sdk macosx metal "${METAL_FLAGS[@]}" -c "$src" -I"$GENERATED_METAL" -o "$air" 2>"$TMP/metal.err"; then
    if grep -q "missing Metal Toolchain" "$TMP/metal.err" 2>/dev/null; then
      echo "error: the Xcode Metal Toolchain is missing." >&2
      echo "run: xcodebuild -downloadComponent MetalToolchain" >&2
    fi
    cat "$TMP/metal.err" >&2
    exit 1
  fi
  AIR_FILES+=("$air")
done

xcrun -sdk macosx metallib "${AIR_FILES[@]}" -o "$OUT_METALLIB"
printf '%s' "$CURRENT_HASH" > "$HASH_FILE"
echo "OK: wrote $OUT_METALLIB ($(du -h "$OUT_METALLIB" | cut -f1))"
