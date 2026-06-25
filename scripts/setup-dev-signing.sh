#!/usr/bin/env bash
# Create a stable, self-signed code-signing identity ("KeyScribe Local") in the login keychain so
# macOS TCC grants (Microphone / Accessibility) survive rebuilds. Ad-hoc signing
# pins the TCC requirement to the binary's cdhash, which changes every build — so grants silently
# drop. A fixed certificate pins the requirement to the cert leaf instead, so grants persist.
# Idempotent: re-running is a no-op once the identity exists.
set -euo pipefail

CERT_NAME="KeyScribe Local"
LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
EXPORT_PASSPHRASE="keyscribe-local"

if security find-identity -v -p codesigning | grep -qF "$CERT_NAME"; then
  echo "✓ Code-signing identity '$CERT_NAME' already present — nothing to do."
  exit 0
fi

# macOS's /usr/bin/openssl is LibreSSL, which cannot emit the legacy-MAC PKCS#12 that `security
# import` is able to read. A real OpenSSL 3.x (Homebrew) is required for the `-legacy` export below.
pick_openssl() {
  local candidate
  for candidate in \
    "$(brew --prefix openssl@3 2>/dev/null)/bin/openssl" \
    /opt/homebrew/opt/openssl@3/bin/openssl \
    /usr/local/opt/openssl@3/bin/openssl \
    "$(command -v openssl 2>/dev/null)"; do
    [ -x "$candidate" ] || continue
    case "$("$candidate" version 2>/dev/null)" in
      "OpenSSL 3."*) printf '%s' "$candidate"; return 0 ;;
    esac
  done
  return 1
}

if ! OPENSSL="$(pick_openssl)"; then
  echo "✗ Need OpenSSL 3 (system LibreSSL will not work). Install it: brew install openssl@3" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/req.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = ${CERT_NAME}
[v3]
basicConstraints     = critical, CA:false
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/req.cnf" 2>/dev/null

"$OPENSSL" pkcs12 -export -legacy -macalg sha1 \
  -name "$CERT_NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "pass:${EXPORT_PASSPHRASE}"

# -A lets codesign use the key without an interactive keychain prompt on every build.
security import "$WORK/identity.p12" -k "$LOGIN_KEYCHAIN" -P "$EXPORT_PASSPHRASE" -A

# A self-signed cert is untrusted by default; without this, codesign rejects it (CSSMERR_TP_NOT_TRUSTED)
# and the identity won't even list under `security find-identity -v`.
if ! security add-trusted-cert -r trustRoot -p codeSign "$WORK/cert.pem" 2>/dev/null; then
  echo "! Could not auto-trust the certificate. In Keychain Access, find '$CERT_NAME' and set" >&2
  echo "  Trust → Code Signing → Always Trust, then rebuild." >&2
fi

echo "✓ Created code-signing identity '$CERT_NAME'."
echo "  Rebuild with ./make-app.sh (it auto-detects this identity)."
echo "  If TCC grants were already lost under old signatures, run ./scripts/reset-permissions.sh."
