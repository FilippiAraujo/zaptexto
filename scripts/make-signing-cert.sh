#!/bin/zsh
# Creates a self-signed code signing certificate for local builds.
#
# Why: macOS ties Full Disk Access to the app's code signature. An ad-hoc signature
# changes on every build, so macOS asks for permission again each time. Signing every
# build with the same certificate keeps the permission across builds and updates.
#
# The certificate lives in its own keychain (~/Library/Keychains/zaptexto-signing.keychain-db)
# whose random password is stored in your login keychain, so build.sh can sign without
# any prompt. Run once; build.sh uses it automatically.
set -e
NAME="ZapTexto Local Signing"
KC=~/Library/Keychains/zaptexto-signing.keychain-db
SERVICE=zaptexto-signing-keychain

if [[ -f $KC ]] && security find-identity -p codesigning $KC | grep -q "$NAME"; then
  echo "✓ '$NAME' already exists"; exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
P12PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout "pass:$P12PASS"

KCPASS=$(/usr/bin/openssl rand -hex 24)
rm -f $KC
security create-keychain -p "$KCPASS" $KC
security set-keychain-settings $KC                      # never auto-lock
security unlock-keychain -p "$KCPASS" $KC
security import "$TMP/id.p12" -k $KC -P "$P12PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" $KC >/dev/null
security add-generic-password -U -a "$USER" -s $SERVICE -w "$KCPASS" -A >/dev/null

echo "✓ created '$NAME' in $KC"
