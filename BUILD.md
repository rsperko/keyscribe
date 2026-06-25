# Building KeyScribe from source

KeyScribe is not yet distributed as a notarized binary. You build it yourself with the Swift
toolchain — no Apple Developer account, no paid certificate, and no passwords are required.

## New machine setup

Setting up on a fresh machine (or a second computer), in order. The signing cert does **not** come
with the repo — its private key lives only in your login keychain — so each machine needs its own.
Same name, different identity per machine; that is expected and fine.

1. **Install the toolchain** — full Xcode selected (`sudo xcode-select -s /Applications/Xcode.app`)
   and the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`). See **Prerequisites**.
2. **Create the `KeyScribe Local` signing cert** (one-time) so permissions survive rebuilds. Run the
   headless block in **Signing ▸ One-time: create a self-signed signing certificate** (or use the
   Keychain Access GUI steps there). Skip this and the build falls back to ad-hoc — it still works,
   but macOS re-prompts for Mic / Accessibility on every rebuild.
3. **Build and run** — `./make-app.sh && open ./KeyScribeDev.app`. It auto-detects the cert by name.
   (`make-app.sh` defaults to the **dev** variant — see **Build variants** below.)
4. **Re-enter your BYOK API keys** in **Settings ▸ AI Services**. Keys live in this machine's
   keychain, never in the repo.

## Prerequisites

- **macOS 26+ on Apple silicon.**
- **Swift 6.0+** (declared floor — `swift build` refuses an older toolchain). Last verified on
  **Swift 6.3** with current Xcode. `make-app.sh` prints the detected vs. verified toolchain and, if
  yours is older, hints to update Xcode should a compiler error appear — it never blocks the build.
- **Xcode installed and selected** (the Command Line Tools alone are not enough — the build needs
  the full Xcode for Metal and signing):

  ```bash
  sudo xcode-select -s /Applications/Xcode.app
  ```

- **Metal Toolchain** (one-time download — required only by the MLX-based **Qwen3-ASR** engine; the
  other speech engines build and run without it):

  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```

  If you skip this, the build still succeeds and KeyScribe still runs — but selecting a Qwen3-ASR
  engine will crash at runtime with `Failed to load the default metallib`. `make-app.sh` prints a
  warning rather than failing when the toolchain is missing.

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

## Build variants

`make-app.sh` builds a **dev** variant by default so a local build can run alongside an installed
production KeyScribe without colliding over macOS state (TCC permissions, config, Keychain):

| Variant | Command | Bundle | Identity / storage |
| --- | --- | --- | --- |
| **dev** (default) | `./make-app.sh` | `KeyScribeDev.app` | `com.keyscribe.app.dev`, config under `~/Library/Application Support/KeyScribeDev/`, own TCC grants + Keychain (orange menu-bar tint) |
| **production** | `KEYSCRIBE_VARIANT=release ./make-app.sh` | `KeyScribe.app` | `com.keyscribe.app`, config under `…/KeyScribe/` |

Downloaded STT models are a **shared cache** under `…/KeyScribe/models/` for both variants — the dev
build never re-downloads gigabytes. The dev-facing helpers (`scripts/reset-permissions.sh`,
`scripts/verify-live.sh`) take the same `KEYSCRIBE_VARIANT` and default to dev. `release.sh` always
forces the production variant. If you only want one normal build, use `KEYSCRIBE_VARIANT=release`.

`make-app.sh` compiles a release build, assembles the `.app` bundle (including `mlx.metallib` for
Qwen3-ASR), and code-signs it. With no signing identity configured it uses an **ad-hoc** signature,
which is enough to launch and use the app.

## Versioning & releases

Git tags are the single source of truth for the version. `make-app.sh` stamps two keys into
`Resources/Info.plist` at build time — never hand-edit them:

- **`CFBundleShortVersionString`** (marketing version) ← `git describe --tags --dirty`, `v` stripped.
  A build cut exactly on a tag reads clean (`0.1.0`); an untagged dev build gets the full describe
  (`0.1.0-2-gc1dc4af`, with `-dirty` when the tree has uncommitted changes) so it can never be
  mistaken for the release. The About window (**menu ▸ About & Notices…**) shows this at runtime.
- **`CFBundleVersion`** (build number) ← `git rev-list --count HEAD`, the monotonic commit count.
  Sparkle (the M7 updater) orders updates by this number, **not** the marketing string, so it must
  only ever increase. This holds on linear history — avoid rebasing/squashing across a released tag.

Both fall back (`0.1` / `1`) when built from a non-git tarball.

Cutting a release:

1. `git tag -a vX.Y.Z -m "…"` — SemVer. Pre-1.0, bump `Y` for features, `Z` for fixes; reserve
   `1.0.0` for the first build you would hand to a stranger.
2. `./make-app.sh` — reads the tag, stamps the clean version into the bundle.
3. (M7) notarize + staple, then add the build to the Sparkle appcast (EdDSA-signed, ordered by
   `CFBundleVersion`).

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

The dev build auto-detects a self-signed cert named **`KeyScribe Local`**; else it falls back to ad-hoc. It deliberately **ignores** `KEYSCRIBE_SIGN_ID` and `CODESIGN_IDENTITY` — those
are the *release* (Developer ID) identity used by `release.sh`, so an `.envrc` exporting
`KEYSCRIBE_SIGN_ID` won't Developer-ID-sign your dev build. If you want a differently-named dev cert,
name it `KeyScribe Local`.

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

- **`Failed to load the default metallib` when selecting Qwen3-ASR** — the Metal Toolchain wasn't
  installed at build time. Run `xcodebuild -downloadComponent MetalToolchain`, then rebuild with
  `./make-app.sh`.
- **macOS re-prompts for Microphone/Accessibility after every rebuild** — you are
  building ad-hoc. Create the `KeyScribe Local` self-signed cert above so the signature is stable.
- **`xcode-select` points at the Command Line Tools** — run
  `sudo xcode-select -s /Applications/Xcode.app`; the build needs full Xcode.

## Logs

```bash
log stream --predicate 'process == "KeyScribe"' --level debug
```
