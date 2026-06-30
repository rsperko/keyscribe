# Contributing to KeyScribe

Thanks for your interest in KeyScribe. Bug reports, fixes, documentation, and new built-in modes are
all welcome.

## Before you start

KeyScribe has a written design spec, and it is the contract. Read [AGENTS.md](AGENTS.md) for
orientation, then the relevant docs under [`docs/`](docs/) — especially `principles.md`,
`design.md`, and `roadmap.md`. A few invariants are non-negotiable and PRs that break them will be
declined:

- **Speech recognition is always on-device.** There is no cloud speech-to-text, and no PR may add
  one.
- **The only outbound network call is the optional BYOK LLM cleanup**, over a redacted payload.
- **No telemetry or analytics.** Nothing about speech, transcripts, or usage may be collected.
- **No app/mode identity in source.** No `if app == "Slack"`, no per-app presets. A Mode is a named
  bag of config a generic pipeline executes — adding a mode means adding data, not code.
- **The pipeline order in `design.md` §4.2 is load-bearing.** Verbatim tokenizes first, text stages
  run, redaction tokenizes last, restore is strict reverse order. Read the section before touching
  that area.

## Build & run

```bash
git clone https://github.com/rsperko/keyscribe.git
cd keyscribe
./make-app.sh && open ./KeyScribeDev.app   # dev variant — runs alongside an installed KeyScribe
```

`make-app.sh` builds the **dev** variant (`KeyScribeDev.app`) so it never collides with a production
install; `make help` lists the other tasks. Prerequisites (macOS 15+ on Apple silicon, full Xcode,
the Metal Toolchain for the Qwen3-ASR engine), the build variants, and a one-time self-signed cert so
TCC permissions survive rebuilds are covered in [BUILD.md](BUILD.md). Apple Speech is available only
on macOS 26+.

## Project conventions

- **Test-first for pure logic.** The OS-free core lives in `Sources/KeyScribeKit` and is unit-tested
  (`swift test`). Write a failing test that defines the behavior before implementing it. OS edges
  (audio capture, paste, CGEvent hotkeys, SwiftUI) are thin adapters in `Sources/KeyScribe`, covered
  by app-target integration tests through dependency-injection seams.
- **Simplicity first.** Start with the simplest implementation; add abstraction only when a pattern
  actually emerges. Avoid pass-through layers and single-implementation abstractions.
- **Zero code comments** unless they are genuinely necessary — names and structure should carry the
  meaning.
- **File-based storage, no SQLite.** Persisted config carries a `schema_version` and migrates
  forward (`design.md` §5.1).
- **Reuse the UI vocabulary** in `docs/ui_components.md` rather than inventing competing badges or
  status words. **Never overstate privacy** in copy — redaction is best-effort; don't call it
  "secure," "safe," or "private."

## Pull requests

- Keep changes surgical and scoped to the stated goal. If you spot unrelated issues, note them in the
  PR description rather than fixing them in the same diff.
- Make sure `swift build` and `swift test` pass.
- **No AI-tool attribution anywhere in repo content** — not in commit messages, code comments, PR
  titles, or descriptions. No "Co-Authored-By" or "Generated with" trailers.

## License

KeyScribe is licensed under [GPLv3](LICENSE). By contributing, you agree that your contributions are
licensed under the same terms.
