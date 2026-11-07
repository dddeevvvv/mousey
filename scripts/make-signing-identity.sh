#!/bin/bash
# Prints the signing certificate SHA-1 on stdout. Everything runs under an isolated HOME so the
# real login keychain and its search list are never touched.
set -euo pipefail
cd "$(dirname "$0")/.."
S="$PWD/.signing"
FH="$S/fakehome"
K="$S/signing.keychain-db"
PWF="$S/password"
CN="Mousey Local Signing"
sec() { HOME="$FH" security "$@"; }
hash_of() { sec find-certificate -c "$CN" -Z "$K" 2>/dev/null | awk '/SHA-1 hash:/{print $3; exit}'; }

if [ -f "$K" ] && [ -f "$PWF" ]; then
	H=$(hash_of || true)
	if [ -n "$H" ]; then echo "$H"; exit 0; fi
fi

# Replacing the identity changes the app's designated requirement, so both Macs would lose their permission grants.
if [ -e "$K" ]; then
	echo "A signing keychain exists at $K but its certificate cannot be read. Fix or remove it by hand." >&2
	exit 1
fi

umask 077
rm -rf "$S"
mkdir -p "$FH/Library/Preferences" "$FH/Library/Keychains"
chmod 700 "$S"
openssl rand -hex 16 > "$PWF"
chmod 600 "$PWF"
P=$(cat "$PWF")
T=$(mktemp -d "$S/tmp.XXXXXX")
trap 'rm -rf "$T"' EXIT

cat > "$T/openssl.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$CN
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$T/openssl.cnf" -keyout "$T/key.pem" -out "$T/cert.pem" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/id.p12" -passout "file:$PWF" 2>/dev/null ||
	openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/id.p12" -passout "file:$PWF"

sec create-keychain -p "$P" "$K"
sec set-keychain-settings "$K"
sec unlock-keychain -p "$P" "$K"
sec import "$T/id.p12" -k "$K" -P "$P" -T /usr/bin/codesign -f pkcs12 >/dev/null
sec set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$P" "$K" >/dev/null
sec list-keychains -d user -s "$K"
rm -f "$T/key.pem" "$T/id.p12"
hash_of
