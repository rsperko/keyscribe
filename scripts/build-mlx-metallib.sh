#!/usr/bin/env bash
# Build MLX's Metal shader library and place it beside the SwiftPM executable output
# (.build/<config>/mlx.metallib), where MLX's colocated lookup finds it first.
#
# Why this script exists: SwiftPM's *native* build system does not compile .metal sources, so
# `swift build` produces no metallib, and Qwen3-ASR terminates the app at its first GPU call ("Failed
# to load the default metallib"). Xcode's build engine does compile them — which is why a downstream
# Xcode build needs none of this. See BUILD.md.
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
  cat <<'USAGE'
Usage: scripts/build-mlx-metallib.sh [debug|release] [--force]
       scripts/build-mlx-metallib.sh --probe

Builds mlx.metallib into .build/<config>/. Skips the build only when the shader sources, the compiler
flags, and the Metal toolchain and SDK are all unchanged. Any failure removes the previous output, so a
library that no longer matches its inputs is never left behind to be bundled.

--probe compiles and links a one-line kernel with the same flags, then exits. It is the real check that
the Metal Toolchain works: Xcode ships a `metal` stub that `xcrun -f metal` finds even when the
toolchain is not installed.

If the toolchain is missing, run:
  xcodebuild -downloadComponent MetalToolchain
USAGE
}

CONFIG="release"
FORCE=0
PROBE=0
for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG="$arg" ;;
    --force) FORCE=1 ;;
    --probe) PROBE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Warning/math flags follow mlx-swift's MTL_COMPILER_FLAGS. The deployment target comes from Info.plist:
# without it Metal refuses the library on macOS releases older than the SDK.
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/Resources/Info.plist")"
METAL_FLAGS=(-x metal -Wall -Wextra -fno-fast-math -Wno-c++17-extensions -Wno-c++20-extensions
  "-mmacosx-version-min=$MIN_MACOS")

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mlx-metallib.XXXXXX")"
OUT_METALLIB=""
trap 'rm -rf "$TMP"; [ -z "$OUT_METALLIB" ] || rm -f "$OUT_METALLIB.partial"' EXIT

toolchain_help() {
  echo "error: the Metal Toolchain can't compile and link shaders." >&2
  echo "run: xcodebuild -downloadComponent MetalToolchain" >&2
}

if [[ "$PROBE" == 1 ]]; then
  printf 'kernel void keyscribe_probe(uint i [[thread_position_in_grid]]) { (void)i; }\n' > "$TMP/probe.metal"
  if xcrun -sdk macosx metal "${METAL_FLAGS[@]}" -c "$TMP/probe.metal" -o "$TMP/probe.air" 2>"$TMP/probe.err" \
    && xcrun -sdk macosx metallib "$TMP/probe.air" -o "$TMP/probe.metallib" 2>>"$TMP/probe.err"; then
    echo "OK: the Metal Toolchain compiles and links shaders"
    exit 0
  fi
  cat "$TMP/probe.err" >&2
  toolchain_help
  exit 1
fi

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

OUT_METALLIB="$OUT_DIR/mlx.metallib"
HASH_FILE="$OUT_DIR/.mlx.metallib.sha"
discard_output() { rm -f "$OUT_METALLIB" "$OUT_METALLIB.partial" "$HASH_FILE"; }

SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done \
  < <(find "$GENERATED_METAL" -type f -name '*.metal' -print0 | LC_ALL=C sort -z)
[[ -f "$FENCE" ]] && SOURCES+=("$FENCE")
if [[ "${#SOURCES[@]}" -eq 0 ]]; then
  echo "error: no .metal sources found under $GENERATED_METAL" >&2
  exit 1
fi

# The toolchain and SDK change the emitted AIR, so they are part of the cache key.
if ! TOOLCHAIN_ID="$( {
  xcrun -sdk macosx metal --version
  xcrun -sdk macosx metallib --version
  xcrun --sdk macosx --show-sdk-version
  xcrun --sdk macosx --show-sdk-build-version
} 2>"$TMP/toolchain.err" )"; then
  cat "$TMP/toolchain.err" >&2
  toolchain_help
  discard_output
  exit 1
fi

CURRENT_HASH="$(
  {
    printf '%s\0' "${METAL_FLAGS[@]}"
    printf '%s\0' "$TOOLCHAIN_ID"
    (cd "$GENERATED_METAL" && find . -type f \( -name '*.metal' -o -name '*.h' \) -print0 \
      | LC_ALL=C sort -z | xargs -0 shasum -a 256)
    if [[ -f "$FENCE" ]]; then shasum -a 256 < "$FENCE"; fi
  } | shasum -a 256 | awk '{print $1}'
)"

if [[ "$FORCE" != "1" && -f "$OUT_METALLIB" && -f "$HASH_FILE" ]] \
  && [[ "$CURRENT_HASH" == "$(cat "$HASH_FILE" 2>/dev/null || true)" ]]; then
  echo "mlx.metallib is up to date — skipping ($(basename "$OUT_METALLIB"))"
  exit 0
fi

discard_output

echo "== compiling ${#SOURCES[@]} Metal sources =="
AIR_FILES=()
for src in "${SOURCES[@]}"; do
  air="$TMP/$(printf '%s' "$src" | shasum -a 256 | cut -c1-16).air"
  if ! xcrun -sdk macosx metal "${METAL_FLAGS[@]}" -c "$src" -I"$GENERATED_METAL" -o "$air" 2>"$TMP/metal.err"; then
    cat "$TMP/metal.err" >&2
    grep -q "missing Metal Toolchain" "$TMP/metal.err" && toolchain_help
    exit 1
  fi
  AIR_FILES+=("$air")
done

# Hash written last: an interrupted build leaves nothing the next run could call up to date.
xcrun -sdk macosx metallib "${AIR_FILES[@]}" -o "$OUT_METALLIB.partial"
mv "$OUT_METALLIB.partial" "$OUT_METALLIB"
printf '%s' "$CURRENT_HASH" > "$HASH_FILE"
echo "OK: wrote $OUT_METALLIB ($(du -h "$OUT_METALLIB" | cut -f1))"
