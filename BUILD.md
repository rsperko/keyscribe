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
   but macOS re-prompts for Mic / Input Monitoring / Accessibility on every rebuild.
3. **Build and run** — `./make-app.sh && open ./KeyScribe.app`. It auto-detects the cert by name.
4. **Re-enter your BYOK API keys** in **Settings ▸ AI Services**. Keys live in this machine's
   keychain, never in the repo.

## Prerequisites

- **macOS 26+ on Apple silicon.**
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
./make-app.sh        # builds + assembles KeyScribe.app (ad-hoc signed by default)
open ./KeyScribe.app
```

`make-app.sh` compiles a release build, assembles the `.app` bundle (including `mlx.metallib` for
Qwen3-ASR), and code-signs it. With no signing identity configured it uses an **ad-hoc** signature,
which is enough to launch and use the app.

## Signing: getting permissions that survive rebuilds

KeyScribe needs three TCC permissions (**Microphone**, **Input Monitoring**, **Accessibility**).
macOS ties those grants to the app's code signature. An **ad-hoc** signature changes on every
rebuild, so macOS treats each rebuild as a new app and **re-prompts for all three permissions**.

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

To use a differently named cert, pass it explicitly (either variable works):

```bash
CODESIGN_IDENTITY="My Cert Name" ./make-app.sh
# or
KEYSCRIBE_SIGN_ID="My Cert Name" ./make-app.sh
```

The first signed build prompts once for keychain access — click **Always Allow**.

## First launch — grant permissions

On first launch, grant the three permissions in **System Settings ▸ Privacy & Security**:

- **Microphone** — on-device speech recognition.
- **Input Monitoring** — the global push-to-talk hotkey (the event tap).
- **Accessibility** — inserting transcribed text into the focused app.

KeyScribe is a menu-bar app (`LSUIElement`) — look for the waveform glyph in the menu bar, not a
Dock icon or window.

> If the **Globe (Fn)** key is mapped to a system action (Emoji, Dictation, Input Source), it may
> fire alongside KeyScribe. Set it to "Do Nothing" in **System Settings ▸ Keyboard**, or pick
> **Right Option** as the trigger key in KeyScribe ▸ Settings.

## Troubleshooting

- **`Failed to load the default metallib` when selecting Qwen3-ASR** — the Metal Toolchain wasn't
  installed at build time. Run `xcodebuild -downloadComponent MetalToolchain`, then rebuild with
  `./make-app.sh`.
- **macOS re-prompts for Microphone/Input Monitoring/Accessibility after every rebuild** — you are
  building ad-hoc. Create the `KeyScribe Local` self-signed cert above so the signature is stable.
- **`xcode-select` points at the Command Line Tools** — run
  `sudo xcode-select -s /Applications/Xcode.app`; the build needs full Xcode.

## Logs

```bash
log stream --predicate 'process == "KeyScribe"' --level debug
```
