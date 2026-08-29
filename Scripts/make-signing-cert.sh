#!/bin/bash
# Generate a self-signed code-signing certificate for release builds.
#
# Why this exists
# ---------------
# An ad-hoc signature has no certificate, so the designated requirement macOS
# records is a hash of one specific build:
#
#     designated => cdhash H"c55efff947efbb05d164f39ddf24d6525cb6f3ff"
#
# TCC stores that requirement when permissions are granted. Every release has a
# different code hash, so every update looks like a different application and
# Input Monitoring, Bluetooth and Accessibility all have to be granted again.
#
# Signing with a certificate — even an untrusted self-signed one — changes the
# requirement to reference the certificate instead:
#
#     designated => identifier "io.github.yourchocomate.asctl"
#                   and certificate root = H"f057e65d1936..."
#
# That is identical for every build signed with the same certificate, so the
# grants survive an update. Measured on two builds with different code hashes:
# the requirement strings matched exactly.
#
# What this does NOT do
# ---------------------
# Gatekeeper still refuses the first launch. That needs notarisation, which
# needs a paid Apple Developer ID. A self-signed certificate is not trusted by
# anything and does not pretend to be; it exists purely to give the signature a
# stable identity so TCC stops treating each release as a new app.
#
# Usage:  Scripts/make-signing-cert.sh [output-dir]     (default: ./signing)
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-signing}"
DAYS=3650
NAME="asctl self-signed"

if [ -e "$OUT/asctl-signing.p12" ]; then
    echo "error: $OUT/asctl-signing.p12 already exists."
    echo "Regenerating gives a different certificate, which resets the designated"
    echo "requirement and loses the permissions on every machine that has the app."
    echo "Delete it deliberately if that is what you want."
    exit 1
fi

mkdir -p "$OUT"
chmod 700 "$OUT"

PASSWORD="$(openssl rand -base64 24)"

echo "generating a $DAYS-day code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$OUT/key.pem" -out "$OUT/cert.pem" -days "$DAYS" \
    -subj "/CN=$NAME/O=asctl" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null

# Legacy PKCS#12 algorithms on purpose.
#
# OpenSSL 3 defaults to AES-256-CBC with SHA-256, which macOS `security import`
# cannot read — it fails with "MAC verification failed (wrong password?)", which
# sends you looking for a password problem that does not exist.
openssl pkcs12 -export \
    -out "$OUT/asctl-signing.p12" \
    -inkey "$OUT/key.pem" -in "$OUT/cert.pem" \
    -passout "pass:$PASSWORD" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

FINGERPRINT="$(openssl x509 -in "$OUT/cert.pem" -noout -fingerprint -sha1 \
    | cut -d= -f2 | tr -d ':')"

printf '%s' "$PASSWORD" > "$OUT/password.txt"
base64 < "$OUT/asctl-signing.p12" > "$OUT/asctl-signing.p12.base64"
chmod 600 "$OUT"/*

cat <<INFO

done. Certificate fingerprint: $FINGERPRINT

Files in $OUT/ (all excluded from git — check .gitignore before committing):
  asctl-signing.p12         the certificate and private key
  asctl-signing.p12.base64  the same, for pasting into a GitHub secret
  password.txt              the export password
  cert.pem / key.pem        the parts, if you ever need them

1. Add two repository secrets, under Settings > Secrets and variables > Actions:

     MACOS_SIGNING_CERT       $OUT/asctl-signing.p12.base64   (paste the contents)
     MACOS_SIGNING_PASSWORD   $OUT/password.txt               (paste the contents)

   pbcopy < $OUT/asctl-signing.p12.base64
   pbcopy < $OUT/password.txt

2. Keep a backup somewhere safe. If this certificate is lost, future releases
   get a different designated requirement and everyone re-grants permissions
   once more. It is not a secret worth guarding against attackers — it signs
   nothing anyone trusts — but it is worth not losing.

3. To sign locally as well, import it into your login keychain:

     security import $OUT/asctl-signing.p12 -k ~/Library/Keychains/login.keychain-db \\
       -P "\$(cat $OUT/password.txt)" -T /usr/bin/codesign
     SIGN_IDENTITY="$NAME" Scripts/make-app.sh

INFO
