#!/bin/zsh
# One-time setup: creates a self-signed "Spruce Code Signing" identity in your login Keychain.
#
#   scripts/make-signing-identity.sh
#
# Every build is then signed with the same identity, so macOS keeps permissions such as
# Screen Recording across updates (with ad hoc signing, each build looks like a new app).
# The private key never leaves your Keychain. Back it up together with the Sparkle key.
set -euo pipefail

NAME="Spruce Code Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists in your Keychain."; exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Spruce Code Signing
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/spruce.p12" -passout "pass:$PASS" 2>/dev/null
# -T lets codesign use the key without asking each time.
security import "$WORK/spruce.p12" -k ~/Library/Keychains/login.keychain-db -P "$PASS" -T /usr/bin/codesign
# macOS asks for your password once here, to trust the certificate for code signing.
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$WORK/cert.pem"

echo "Created \"$NAME\":"
security find-identity -v -p codesigning | grep "$NAME"
