#!/usr/bin/env bash
set -euo pipefail

# Creates a stable, self-signed code-signing identity in the login Keychain so that
# the app's code signature (its "designated requirement") stays constant across rebuilds.
#
# The app reads its token through /usr/bin/security, so this identity is not required for
# Keychain access. It only keeps the locally built app's code signature stable.
#
# One-time: run this once, then rebuild with ./scripts/make-app.sh.
#
# No Apple Developer account required — this is a local self-signed cert. The app stays
# "unidentified developer" to Gatekeeper (same as with ad-hoc); only the Keychain grant
# stability changes.

CERT_CN="Claude Usage Self-Signed"

if security find-identity -v -p codesigning | grep -qF "$CERT_CN"; then
  echo "✓ Signing identity '$CERT_CN' already exists — nothing to do."
  echo "  Sign with:  ./scripts/make-app.sh"
  exit 0
fi

KEYCHAIN="$(security default-keychain | tr -d ' "')"
echo "Login keychain: $KEYCHAIN"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Generating self-signed code-signing certificate…"
cat > "$WORK/cert.conf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = $CERT_CN
[ v3 ]
basicConstraints   = critical, CA:false
keyUsage           = critical, digitalSignature
extendedKeyUsage   = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.conf" 2>/dev/null

# A throwaway passphrase; macOS's importer chokes on empty-password PKCS#12 from OpenSSL 3.
P12_PASS="claude-usage-tmp"
openssl pkcs12 -export -legacy \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/cert.p12" -passout "pass:$P12_PASS" -name "$CERT_CN" 2>/dev/null

echo "Importing into the login keychain (allowlisting codesign)…"
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign

# Allow codesign to use the private key without an interactive prompt each build.
# Needs the login-keychain password; prompted once here.
echo "Authorizing codesign to use the key (enter your login/Keychain password)…"
security set-key-partition-list -S apple-tool:,apple: -s "$KEYCHAIN" >/dev/null 2>&1 || \
  echo "  (set-key-partition-list skipped — codesign may prompt once on first sign; click Always Allow.)"

if security find-identity -v -p codesigning | grep -qF "$CERT_CN"; then
  echo "✓ Identity '$CERT_CN' is valid for code signing."
else
  echo "Marking the certificate as trusted for code signing (may prompt for your password)…"
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"
fi

echo
echo "Done. Next:"
echo "  1) ./scripts/make-app.sh"
echo "  2) cp -R \"Claude Usage.app\" /Applications/"
echo "  3) Launch the app."
