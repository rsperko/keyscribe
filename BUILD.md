# Building KeyScribe from source

This guide is for building KeyScribe yourself. You do not need an Apple Developer account, a paid
certificate, or any passwords for a local build; packaged prerelease DMGs and the Homebrew cask are
covered in [README.md](README.md).

## New machine setup

Setting up on a fresh machine (or a second computer), in order. The signing cert does **not** come
with the repo — its private key lives only in your login keychain — so each machine needs its own.
Same name, different identity per machine; that is expected and fine.

1. **Install the toolchain** — full Xcode selected (`sudo xcode-select -s /Applications/Xcode.app`),
   the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`), and XcodeGen
   (`brew install xcodegen`). See **Prerequisites**.
2. **Create the `KeyScribe Local` signing cert** (one-time) so permissions survive rebuilds. Run the
   headless block in **Signing ▸ One-time: create a self-signed signing certificate** (or use the
   Keychain Access GUI steps there). Skip this and the build falls back to ad-hoc — it still works,
   but macOS re-prompts for Mic / Accessibility on every rebuild.
3. **Build and run** — `./make-app.sh && open ./KeyScribeDev.app`. It auto-detects the cert by name.
   (`make-app.sh` defaults to the **dev** variant — see **Build variants** below.)
4. **Re-enter your AI service credentials** in **Settings ▸ AI Services**. Saved API keys live in
   this machine's keychain, never in the repo. OpenAI-compatible local/proxy endpoints can also use
   No Auth or a token command instead of a saved key.

## Prerequisites

- **macOS 15+ on Apple silicon.** Apple Speech, the zero-download system speech model, is available
  only on macOS 26+; the app hides that model on older supported macOS releases.
- **Xcode installed and selected.** The app is built through an Xcode project, so the Command Line
  Tools alone are **not** enough; `make-app.sh` refuses to build against them. Last verified on
  **Xcode 26.6 / Swift 6.3**. `Package.swift` declares Swift 6.0 as the floor.

  ```bash
  sudo xcode-select -s /Applications/Xcode.app
  ```

- **Metal Toolchain** (one-time download — required):

  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```

  The Qwen3-ASR engine runs on MLX, and Xcode compiles MLX's Metal shaders as part of the package
  build. `make-app.sh` stops before generating the project if it cannot compile a test shader, and
  runs `KeyScribe --mlx-smoke` on the built product before it replaces the existing app, so a build
  can never ship Qwen3 models that crash on use.

- **XcodeGen** (`brew install xcodegen`). The app definition is `App/project.yml`; the `.xcodeproj` is
  generated on every build and never committed.

## Build & run

```bash
git clone https://github.com/rsperko/keyscribe.git
cd keyscribe
./make-app.sh        # builds + assembles KeyScribeDev.app (dev variant; ad-hoc signed by default)
open ./KeyScribeDev.app
```

Common tasks are also exposed through **`make`** — run `make help` to list them (`make build`, `make
run`, `make release BUMP=patch`, `make test`, `make setup`, `make reset-permissions`, `make verify`,
`make icon`, `make clean`). It's a thin front door over the same scripts documented here.

## How the build works

One shared Xcode app definition owns everything that turns the Swift package into a runnable app.
`App/template.yml` holds the `KeyScribeAppBase` target template: the functional resources, the
package products it links, `Resources/Info.plist` (Xcode substitutes the `$(...)` build settings in
it), and a post-build phase that copies the GPLv3 license, `THIRD-PARTY-NOTICES.md`, and the license
and notice files of every package pinned in the build's lockfile into `Contents/Resources/Legal`.
`App/project.yml` includes it and adds upstream's two targets, `KeyScribeDev` and `KeyScribe`, each
compiling the entry file `Sources/KeyScribeMain/main.swift` and copying `Resources/AppIcon.icns`. `Package.swift` keeps describing the code and its pinned
dependencies; Xcode does assembly, resource handling, framework embedding, and signing.

`make-app.sh` and `release.sh` both call `scripts/prepare-xcode-project.sh`, which checks the
toolchain, runs `xcodegen`, and copies the root `Package.resolved` into the generated project so there
is exactly one source of truth for dependency pins (every `xcodebuild` call also passes
`-disableAutomaticPackageResolution`). Two settings must reach the package targets and cannot live in
`project.yml`, so every invocation passes `-xcconfig App/Config/Packages.xcconfig`: `ARCHS=arm64` (the
speech engines have no x86_64 build) and `MTL_FAST_MATH=NO` (MLX's own builds use `-fno-fast-math`).
Build products land under `.build/xcode/`.

A plain `swift build` still works and produces `.build/release/KeyScribe` for quick iteration and the
developer CLI flags, but that binary carries no Metal shader library, so Qwen3-ASR crashes from it.
Use the `.app`'s binary for anything that touches MLX.

### Building a downstream distribution

A rebranded distribution includes the shared template (`App/template.yml`) from its own `project.yml`
and adds its own target, instead of copying build logic:

```yaml
name: MyApp
include:
  - path: ../keyscribe/App/template.yml     # wherever the upstream mirror sits
settings:
  base:
    KEYSCRIBE_ROOT: $(SRCROOT)/../keyscribe   # the same location, for paths the build needs at build time
targets:
  MyApp:
    templates: [KeyScribeAppBase]
    sources:
      - path: MyApp/main.swift        # your entry file: construct AppDelegate, set delegate.updater, app.run()
      - path: MyApp/AppIcon.icns      # your icon; Resources/Info.plist names the file AppIcon
        buildPhase: resources
    settings:
      base:
        PRODUCT_NAME: MyApp
        PRODUCT_BUNDLE_IDENTIFIER: com.example.myapp
        CODE_SIGN_IDENTITY: "Developer ID Application"
        DEVELOPMENT_TEAM: YOURTEAMID
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGN_ENTITLEMENTS: $(KEYSCRIBE_ROOT)/KeyScribe.entitlements
```

The template owns the functional resources, package products, `Resources/Info.plist`, and the license
phase. The entry file and the app icon are the target's, so exactly one `main.swift` is compiled and
exactly one `AppIcon.icns` is copied. Name your icon file `AppIcon.icns`, since `Resources/Info.plist`
refers to it by that name.

**Commit your own `Package.resolved`:** upstream's pins plus the pins of any package your target adds
(your updater, for example). A copy of upstream's file alone is not enough once you add a package, because
frozen resolution rejects a lockfile that is missing a dependency. Generate the project and seed that
lockfile with upstream's helper, passing the version inputs (a mirror's git history is not this repo's, so
they are inputs, not derived):

```bash
KEYSCRIBE_VERSION=1.2.0 KEYSCRIBE_BUILD=42 KEYSCRIBE_SCM_REVISION="$(git rev-parse HEAD)" \
  ../keyscribe/scripts/prepare-xcode-project.sh --spec project.yml --project-dir . --lockfile Package.resolved
```

It fails, naming the first one, if any upstream pin is missing from your lockfile or sits at a different
revision: update those pins to upstream's and keep your own. On success it prints `MARKETING_VERSION`,
`CURRENT_PROJECT_VERSION`, and `KEYSCRIBE_SCM_REVISION` settings, one per line. Pass them to `xcodebuild`
together with `-disableAutomaticPackageResolution -xcconfig ../keyscribe/App/Config/Packages.xcconfig`.
Signing identity, entitlements, hardened runtime, updater, and export options stay on your target;
upstream's Sparkle updater is linked only by the public `KeyScribe` target and never by the template.

## Build variants

`make-app.sh` builds a **dev** variant by default so a local build can run alongside an installed
production KeyScribe without colliding over macOS state (TCC permissions, config, Keychain):

| Variant | Command | Bundle | Identity / storage |
| --- | --- | --- | --- |
| **dev** (default) | `./make-app.sh` | `KeyScribeDev.app` | `com.keyscribe.app.dev`, config under `~/Library/Application Support/KeyScribeDev/`, own TCC grants + Keychain (orange menu-bar tint) |
| **production** | `KEYSCRIBE_VARIANT=release ./make-app.sh` | `KeyScribe.app` | `com.keyscribe.app`, config under `…/KeyScribe/`; ad-hoc unless `KEYSCRIBE_SIGN_ID` is set |

Downloaded STT models are a **shared cache** under `…/KeyScribe/models/` for both variants — the dev
build never re-downloads gigabytes. The dev-facing helpers (`scripts/reset-permissions.sh`,
`scripts/verify-live.sh`) take the same `KEYSCRIBE_VARIANT` and default to dev. `release.sh` always
builds the production target. If you only want one normal build, use `KEYSCRIBE_VARIANT=release`.

## Versioning & releases

Git tags are the single source of truth for the version. `scripts/prepare-xcode-project.sh` derives
two values that Xcode stamps into `Resources/Info.plist` at build time — never hand-edit them:

- **`CFBundleShortVersionString`** (marketing version) ← `git describe --tags --dirty`, `v` stripped.
  A build cut exactly on a tag reads clean (`0.1.0`); an untagged dev build gets the full describe
  (`0.1.0-2-gc1dc4af`, with `-dirty` when the tree has uncommitted changes) so it can never be
  mistaken for the release. The About window (**menu ▸ About & Notices…**) shows this at runtime.
- **`CFBundleVersion`** (build number) ← `git rev-list --count HEAD`, the monotonic commit count.
  Sparkle will order updates by this number, **not** the marketing string, so it must only ever
  increase. This holds on linear history — avoid rebasing/squashing across a released tag.

Both fall back (`0.1` / `1`) when built from a non-git tarball, and `KEYSCRIBE_VERSION` /
`KEYSCRIBE_BUILD` override them.

Cutting a release:

1. `git tag -a vX.Y.Z -m "…"` — SemVer. Pre-1.0, bump `Y` for features, `Z` for fixes; reserve
   `1.0.0` for the first build you would hand to a stranger.
2. `./release.sh` — archives and exports the production target from the tag (Developer ID, hardened
   runtime, entitlements, Sparkle embedded and signed by Xcode), notarizes/staples when notary
   credentials are configured, and writes `KeyScribe-<version>.dmg`.
3. `make publish` — after reviewing the built DMG, pushes the tag, creates or updates the GitHub
   release asset, and refreshes the Homebrew cask in the tap checkout.

## Signing: getting permissions that survive rebuilds

KeyScribe needs two TCC permissions (**Microphone**, **Accessibility**).
macOS ties those grants to the app's code signature. An **ad-hoc** signature changes on every
rebuild, so macOS treats each rebuild as a new app and **re-prompts for both permissions**.

macOS does not require an Apple-issued certificate here — it only needs a signature that is *valid
and stable*. A **self-signed certificate** satisfies that, so your grants persist across rebuilds.
This is the recommended setup if you plan to rebuild.

### One-time: create a self-signed signing certificate

1. Open **Keychain Access**.
2. Menu: **Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…**
3. **Name:** `KeyScribe Local`
4. **Identity Type:** Self Signed Root
5. **Certificate Type:** Code Signing
6. Create it (defaults are fine).

Or create the same cert headlessly (no Keychain Access GUI). Note the OpenSSL-3 `-legacy`
flag on the PKCS#12 export — without it Apple's `security` rejects the import with
"MAC verification failed":

```bash
cat > /tmp/kc-cert.cnf <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = KeyScribe Local
[ v3 ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -keyout /tmp/kc-key.pem -out /tmp/kc-cert.pem \
  -days 3650 -nodes -config /tmp/kc-cert.cnf -extensions v3
openssl pkcs12 -export -legacy -inkey /tmp/kc-key.pem -in /tmp/kc-cert.pem \
  -out /tmp/kc.p12 -name "KeyScribe Local" -passout pass:keyscribe
# -A lets codesign use the key without a per-build prompt; -T scopes it to codesign.
security import /tmp/kc.p12 -k ~/Library/Keychains/login.keychain-db -P keyscribe \
  -A -T /usr/bin/codesign
# Mark it trusted for code signing so `security find-identity -v -p codesigning` lists it
# (that is what make-app.sh greps). User-domain trust — no sudo.
security add-trusted-cert -r trustRoot -p codeSign /tmp/kc-cert.pem
rm -f /tmp/kc-cert.cnf /tmp/kc-key.pem /tmp/kc-cert.pem /tmp/kc.p12
```

`make-app.sh` auto-detects a cert named `KeyScribe Local` — no further configuration needed:

```bash
./make-app.sh        # now signs with "KeyScribe Local" automatically
```

The dev build auto-detects a self-signed cert named **`KeyScribe Local`**; else it falls back to
ad-hoc. It deliberately **ignores** `KEYSCRIBE_SIGN_ID` and `CODESIGN_IDENTITY` — those are the
*release* (Developer ID) identity used by `release.sh`, so an `.envrc` exporting `KEYSCRIBE_SIGN_ID`
won't Developer-ID-sign your dev build. If you want a differently-named dev cert, name it
`KeyScribe Local`.

The first signed build prompts once for keychain access — click **Always Allow**.

## First launch — grant permissions

On first launch, grant the two permissions in **System Settings ▸ Privacy & Security**:

- **Microphone** — on-device speech recognition.
- **Accessibility** — detecting a modifier-key trigger (the event tap watches modifier flags only) and
  inserting transcribed text into the focused app. (A key+modifier trigger like ⌃⌥E registers as a
  system hotkey via `RegisterEventHotKey` and needs no permission.)

KeyScribe is a menu-bar app (`LSUIElement`) — look for the waveform glyph in the menu bar, not a
Dock icon or window.

> If the **Globe (Fn)** key is mapped to a system action (Emoji, Dictation, Input Source), it may
> fire alongside KeyScribe. Set it to "Do Nothing" in **System Settings ▸ Keyboard**, or pick
> **Right Option** as the trigger key in KeyScribe ▸ Settings.

## Troubleshooting

- **`Failed to load the default metallib` when selecting Qwen3-ASR** — the binary has no shader
  library. A bare `swift build` never produces one; build through `./make-app.sh` and run the `.app`.
  If the `.app` itself fails, run `xcodebuild -downloadComponent MetalToolchain`, rebuild, and confirm
  with `KeyScribeDev.app/Contents/MacOS/KeyScribe --mlx-smoke`.
- **macOS re-prompts for Microphone/Accessibility after every rebuild** — you are
  building ad-hoc. Create the `KeyScribe Local` self-signed cert above so the signature is stable.
- **`xcode-select` points at the Command Line Tools** — `make-app.sh` stops with this before
  building. Run `sudo xcode-select -s /Applications/Xcode.app`; the build needs full Xcode.
- **`xcodegen not found`** — `brew install xcodegen`.
- **`an out-of-date resolved file was detected`** — the generated project's lockfile disagrees with
  `Package.swift`. `scripts/prepare-xcode-project.sh` copies the root `Package.resolved` in on every
  build, so this means the root lockfile itself is stale: run `swift package resolve`, review the
  `Package.resolved` diff, and rebuild.
- **`unable to spawn process 'metal'`** — there is no Metal compiler. On a Command-Line-Tools-only
  install select full Xcode as above; otherwise install the Metal Toolchain.

## Logs

```bash
log stream --predicate 'process == "KeyScribe"' --level debug
```
