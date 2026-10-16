#!/bin/bash
# The stable local code-signing identity for the Bonjour gates (LAN-play plan D12). The plan signs the automation app
# with one certificate so its designated requirement never changes. Spike (c) found that macOS 27 stores the
# local-network decision per bundle ID and enforces it only for executables LaunchServices has registered, so what
# keeps the permission across rebuilds is installing the app at one fixed path and registering it
# (scripts/prepare-bonjour.sh and the Bonjour gates do both); the identity is kept as the plan specifies.
#
#   bash scripts/automation-identity.sh create        once per test host; idempotent
#   bash scripts/automation-identity.sh sign <app>    sign a bundle with it (nested code first)
#   bash scripts/automation-identity.sh fingerprint   SHA-1 of the certificate, for bonjour-ready.json
#
# The identity lives in its own keychain, not the login keychain: an SSH session cannot unlock the login keychain
# without the account password, which no script holds. The keychain's random password stays in a 0600 file beside
# the host-role marker; neither ever enters the repository.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/test_host.py "the automation signing identity" || exit 1
name="Checkmate Automation Local"
keychain="$HOME/Library/Keychains/checkmate-automation.keychain-db"
secret="$HOME/.config/checkmate/automation-keychain.pass"

unlock() {
  [[ -f "$keychain" && -f "$secret" ]] || { echo "No automation identity: run scripts/automation-identity.sh create" >&2; exit 1; }
  security unlock-keychain -p "$(cat "$secret")" "$keychain"
}
fingerprint() {
  unlock
  security find-certificate -c "$name" -Z "$keychain" | awk '/SHA-1 hash:/ {print $3}'
}

case "${1:-}" in
create)
  if [[ -f "$keychain" && -f "$secret" ]] && unlock && security find-identity -p codesigning "$keychain" | grep -q "\"$name\""; then
    echo "Identity exists: $(fingerprint)"; exit 0
  fi
  [[ ! -e "$keychain" ]] || { echo "$keychain exists without a usable identity; remove it by hand after checking it" >&2; exit 1; }
  mkdir -p "$(dirname "$secret")"
  umask 077
  openssl rand -hex 24 > "$secret"
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  cat > "$work/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.conf" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
  transfer=$(openssl rand -hex 16)
  openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" -passout "pass:$transfer" -out "$work/identity.p12" 2>/dev/null \
    || openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" -passout "pass:$transfer" -out "$work/identity.p12"
  security create-keychain -p "$(cat "$secret")" "$keychain"
  security set-keychain-settings "$keychain"   # no auto-lock timeout
  unlock
  security import "$work/identity.p12" -k "$keychain" -P "$transfer" -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(cat "$secret")" "$keychain" > /dev/null
  security find-identity -p codesigning "$keychain" | grep -q "\"$name\"" || { echo "Identity not usable for code signing" >&2; exit 1; }
  echo "Identity created: $(fingerprint)"
  ;;
sign)
  app=${2:?Usage: automation-identity.sh sign <app>}
  unlock
  hash=$(fingerprint)
  # Nested executables first, then the bundle, as build.sh does for its ad-hoc signature.
  while IFS= read -r nested; do
    [[ "$nested" == "$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")" ]] && continue
    codesign --force --sign "$hash" --keychain "$keychain" "$nested"
  done < <(find "$app/Contents/MacOS" -type f -perm -u+x)
  codesign --force --sign "$hash" --keychain "$keychain" "$app"
  codesign --verify --strict "$app"
  ;;
fingerprint) fingerprint ;;
*) echo "Usage: automation-identity.sh create|sign <app>|fingerprint" >&2; exit 1 ;;
esac
