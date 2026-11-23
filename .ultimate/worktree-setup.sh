#!/bin/sh
set -e
# Seed a fresh worktree's SwiftPM state from the source checkout so `swift build`/`swift test`
# don't refetch every dependency. APFS copy-on-write clones (`cp -c`): instant and free until written.
# Each worktree keeps its own .build, so its builds never wait on the source checkout's .build lock.
[ -n "$ULTIMATE_SOURCE" ] && [ -d "$ULTIMATE_SOURCE/.build" ] || exit 0
mkdir -p .build
for d in repositories checkouts artifacts; do
  [ -e ".build/$d" ] || [ ! -d "$ULTIMATE_SOURCE/.build/$d" ] || cp -cR "$ULTIMATE_SOURCE/.build/$d" ".build/$d"
done
[ -e .build/workspace-state.json ] || cp -c "$ULTIMATE_SOURCE/.build/workspace-state.json" .build/ 2>/dev/null || true
