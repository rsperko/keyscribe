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
# Why pin at all: Swift 6.4 flips SwiftPM's default from `native` to `swiftbuild`. The app itself is
# built through Xcode (App/project.yml), so this only governs `swift build` / `swift test`: under
# swiftbuild, products move out of .build/<config> and MLX's .metal sources join the build. Moving tests
# to swiftbuild is a separate, deliberate change (verify with `swift test --build-system swiftbuild`);
# 6.4 marks `native` deprecated, so it has a deadline.
set -euo pipefail

SUBCOMMAND="${1:-build}"
if swift "$SUBCOMMAND" --help 2>/dev/null | grep -q -- '--build-system'; then
  echo "--build-system native"
fi
