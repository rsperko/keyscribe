# Build, variants, and release

Read before changing the package layout, the Xcode app definition, signing, build variants, `make-app.sh`, `release.sh`, or the release gate.

## Package layout

Top-level SwiftPM (`Package.swift`): `Sources/KeyScribeKit` (pure) + `Sources/KeyScribe` (app) +
`Tests/KeyScribeKitTests` (pure-logic) + `Tests/KeyScribeTests` (app-target via
`@testable import KeyScribeApp`, for OS-edge regression through DI seams). **The app's code is the
`KeyScribeApp` library target** (module `KeyScribeApp`, path `Sources/KeyScribe`), exported alongside
`KeyScribeKit` as a **library product** so a downstream build through a standard Xcode project links
one product and inherits every dependency — and its pins — transitively, instead of re-declaring them
in a second place that silently drifts. `Sources/KeyScribeMain/main.swift` is the only file in the
`KeyScribe` **executable** target and is also the entry file every Xcode app target compiles. Keep the app
target's public surface minimal — only what `main.swift` and a downstream entry file must call; everything
else stays `internal`. Grep `^public` in `Sources/KeyScribe` before adding one.

## The Sparkle gate

**The Sparkle gate is a per-target compilation condition, not `canImport`:** `Package.swift` depends on
Sparkle unconditionally (so its pin lives in the one `Package.resolved`) but only `KeyScribeSparkle` links
it, and only the public app target in `App/project.yml` links that, setting
`SWIFT_ACTIVE_COMPILATION_CONDITIONS=KEYSCRIBE_SPARKLE` so `main.swift`'s `#if KEYSCRIBE_SPARKLE` block
constructs the updater. `canImport(KeyScribeSparkle)` would read true for the dev target too once the
public target's module sits in shared DerivedData (measured), so do not "simplify" it to that. Apps are
built through **the shared Xcode app definition**: `App/template.yml` (XcodeGen) holds the
`KeyScribeAppBase` target template — functional resources, package wiring, `Resources/Info.plist` with
`$(...)` substitution, and a post-build phase that runs `scripts/collect-licenses.sh` over the packages
pinned in the project's lockfile (never the bare checkouts directory, so a stale checkout cannot ship its
notice) — and `App/project.yml` includes it and adds this repo's thin targets, `KeyScribeDev` and `KeyScribe`,
each listing `Sources/KeyScribeMain` and `Resources/AppIcon.icns` as its own sources so a downstream target
can list its own entry file and icon instead (two icons at one output path collide). Paths the build needs at build time go through the `KEYSCRIBE_ROOT` setting (XcodeGen rewrites
source paths for an including spec but copies settings verbatim). `scripts/prepare-xcode-project.sh` checks the toolchain,
runs `xcodegen`, **seeds the generated project's lockfile from the root `Package.resolved` on every build**
(`-disableAutomaticPackageResolution` rejects a lockfile that violates the manifest but silently keeps one
that drifted inside a `from:` range, so the copy is the real guard; a downstream passes its own lockfile
with `--lockfile`, and the script fails unless every upstream pin matches it), and prints the version settings
(`MARKETING_VERSION` from `git describe`, `CURRENT_PROJECT_VERSION` from the commit count,
`KEYSCRIBE_SCM_REVISION`; `KEYSCRIBE_VERSION`/`KEYSCRIBE_BUILD`/`KEYSCRIBE_SCM_REVISION` env override them
for a mirror whose git history is not this repo's), plus `KEYSCRIBE_FLUIDAUDIO_REVISION`, upstream's FluidAudio
pin, which the spoken-audio report names (`Info.plist` `FluidAudioRevision`). A build that did not pass it gets it
from the build's own lockfile in the template's post-build phase (`scripts/stamp-dependency-revisions.sh`), on every
build, so an incremental build after a pin bump never keeps an earlier stamp; it reads "unknown" only when that
lockfile has no FluidAudio pin. `./make-app.sh` builds the **dev** target with the
stable self-signed cert (**`KeyScribe Local`**) for persistent TCC, else ad-hoc; it **ignores**
`KEYSCRIBE_SIGN_ID` / `CODESIGN_IDENTITY` for dev (those are the release Developer ID identity, so an
`.envrc` for `release.sh` never leaks into dev). `release.sh` archives and exports the public target;
Xcode signs Sparkle's helpers, the framework, the binary, and the bundle inside-out with hardened runtime
itself, so there is no re-sign block. **A downstream distribution `include:`s the template and adds its
own target** with its own identity, signing, entry file (`main.swift` that sets `delegate.updater`), and
export options — it never edits upstream source. Full from-source build, prerequisites, and signing live
in **`BUILD.md`**.

## Build variants

**Build variants** (`KEYSCRIBE_VARIANT`, default `dev`; `AppVariant` resolves the running bundle to
dev, production, or a `custom` white-label identity): `./make-app.sh` builds the isolated
**KeyScribeDev.app** (`com.keyscribe.app.dev` — its own config dir, TCC grants, and Keychain service;
orange menu-bar tint) so it runs alongside an installed production app; `./release.sh` forces the
production **KeyScribe.app** (`com.keyscribe.app`, Developer ID, hardened runtime, notarized + stapled
DMG). `./release.sh patch|minor|major` bumps the tag, builds, notarizes, and prints the publish steps —
it stops before pushing anything public. Variant plumbing: `AppVariant` (KeyScribeKit) resolved through
`KeyScribePaths`/`KeychainStore`; **downloaded models are shared** (pinned to `KeyScribe/models`, never
per-variant — the easy-to-miss part).

## Shipping a release

**Shipping a release** (`./release.sh patch|minor|major` → `make ship`): the build + double Apple
notarization (app, then DMG) takes ~10–30 min, so it is a **background + poll** job, not a foreground
one (see the global "Command Execution" discipline). Write the log to a file and `tail` it. Two resume
footguns: (1) if a `patch`/`minor`/`major` run already created the next tag, re-running with the bump
arg creates a *duplicate later* tag and errors on `tag already exists` — instead resume with a **bare
`./release.sh`** (or `make ship` with no bump) which builds from the existing tag. (2) an orphaned
`swift-package`/`swift-test` can hold a stale `.build/.lock` (it caches the PID, rechecks, but a wedged
process never clears it) and silently block all builds — if a build reports `Another instance of
SwiftPM (PID: …) is already running` for minutes, confirm that PID is dead (`ps -p <pid>`), then
`rm -f .build/.lock` and relaunch. Do not stack concurrent `make ship`/`make release` invocations:
they race on the lock and on `make publish`.

## The release gate

**The release gate is mandatory and enforced: `make preflight` (→ `scripts/preflight.sh`) must pass
before anything goes public.** `swift test` green is NOT sufficient — it runs on the dev build, but
releases break on what only exists in the notarized artifact (TCC grants rebinding to the new
signature, hardened-runtime entitlements, the signed MLX shader bundle, Gatekeeper quarantine,
first-run onboarding, the permission-gated trigger matrix). Preflight runs the automated build/packaging
+ functional gates and walks the human smoke checks on the freshly-installed production app, then writes
a commit-keyed stamp (`.preflight-pass`). `scripts/publish.sh` **refuses to publish without a matching
stamp** (override: `KEYSCRIBE_SKIP_PREFLIGHT=1`, i.e. shipping unverified). `make ship` chains
release → preflight → publish. Full contract + rationale: `docs/development/release_testing.md`.

## Entitlements and Info.plist

`KeyScribe.entitlements` (hardened-runtime) is carried by the public `KeyScribe` target in
`App/project.yml`; the dev target omits it (a teamless self-signed cert can't authorize it). Keep its XML
comments free of `--` — AMFI's strict parser rejects them. The bundle's `Info.plist` is a tracked
source at `Resources/Info.plist`; Xcode substitutes `CFBundleShortVersionString` (git tag),
`CFBundleVersion` (commit count), and the variant's bundle id/name — don't hand-edit those keys.
