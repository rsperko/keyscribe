#!/usr/bin/env bash
# Print the SwiftPM flags that pin the build system to `native`, or nothing on a toolchain with no
# --build-system knob (verified present on 6.2 and 6.3; the repo's floor is 6.0). Takes the
# subcommand being pinned so the probe asks the same `swift <sub> --help` the caller is about to
# run — never assume `build` and `test` agree on a toolchain neither of us can test. Callers splice
# the output in unquoted:
#
#   BUILD_SYSTEM="$(./scripts/swiftpm-build-system.sh)"        # defaults to `build`
#   swift build -c release $BUILD_SYSTEM --product KeyScribe
#   swift test "$(./scripts/swiftpm-build-system.sh test)"
#
# Why pin at all: Swift 6.4 flips SwiftPM's default from `native` to `swiftbuild`, and this repo
# depends on two things that flip with it.
#
#   1. Product location. native writes .build/<config>/; swiftbuild writes .build/out/Products/
#      <Config>/ and creates no .build/release symlink at all. make-app.sh copies
#      .build/release/KeyScribe into the .app and scripts/build-mlx-metallib.sh writes its metallib
#      beside it, so the default flip breaks the packaging step on any machine — Xcode and Metal
#      Toolchain present or not.
#   2. Metal shaders. native does not compile .metal sources, which is the whole reason
#      scripts/build-mlx-metallib.sh exists and gets to choose MLX's *curated* 3.0 MB kernel set.
#      swiftbuild compiles them as part of `swift build`, which makes the Metal Toolchain a hard
#      build requirement (it is optional today — only Qwen3-ASR needs it) and hands MLX a shader
#      library this repo never picked. On a Command-Line-Tools-only install there is no `metal` at
#      all, so the build dies with "unable to spawn process 'metal'".
#
# So the pin is not conservatism for its own sake: it keeps the notarized artifact identical
# regardless of which toolchain built it. Moving to swiftbuild is a deliberate migration (product
# paths, bundling + signing MLX's resource bundle, preflight, release.sh) — see BUILD.md
# "Prerequisites". Swift 6.4 marks `native` deprecated, so that migration has a deadline.
set -euo pipefail

SUBCOMMAND="${1:-build}"
if swift "$SUBCOMMAND" --help 2>/dev/null | grep -q -- '--build-system'; then
  echo "--build-system native"
fi
