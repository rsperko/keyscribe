#!/usr/bin/env bash
# Qwen3-ASR runtime check shared by make-app.sh (staged app) and preflight's a-metallib: both Qwen ids
# runnable, and MLX executes a kernel from the shader library in its own process.
set -euo pipefail

EXE="${1:?usage: scripts/validate-qwen-runtime.sh <path to the KeyScribe executable>}"
[ -x "$EXE" ] || { echo "error: $EXE is not an executable" >&2; exit 1; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/keyscribe-validate.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

bounded() { /usr/bin/perl -e 'alarm shift; exec @ARGV or die "exec $ARGV[0]: $!\n"' "$@"; }

if ! LIST="$(bounded 60 "$EXE" --config-dir "$SCRATCH" --list-engines)"; then
  echo "error: $EXE --list-engines failed" >&2
  exit 1
fi

status=0
for id in qwen3-asr-0.6b qwen3-asr-1.7b; do
  state="$(printf '%s\n' "$LIST" | awk -F'\t' -v id="$id" '$1 == id { print $2 }')"
  case "$state" in
    installed|missing) ;;
    "") echo "error: $id is not listed by --list-engines" >&2; status=1 ;;
    *) echo "error: $id is '$state' — this build cannot run Qwen3-ASR" >&2; status=1 ;;
  esac
done

if ! bounded 120 "$EXE" --config-dir "$SCRATCH" --mlx-smoke; then
  echo "error: $EXE --mlx-smoke failed — MLX could not load or execute its shader library" >&2
  status=1
fi

[ "$status" = 0 ] && echo "OK: Qwen3-ASR runtime validated for $EXE"
exit "$status"
