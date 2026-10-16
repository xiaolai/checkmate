#!/bin/bash
# Builds Tools/lan-vm.swift with the virtualization entitlement it needs (ad-hoc signature; it never leaves the host).
#   bash Tools/lan-vm.sh <output-binary>
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/test_host.py "the LAN spike's virtual machines" || exit 1
output=${1:?Usage: lan-vm.sh <output-binary>}
entitlements=$(mktemp)
trap 'rm -f "$entitlements"' EXIT
cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.virtualization</key><true/></dict></plist>
PLIST
xcrun swiftc -O Tools/lan-vm.swift -o "$output"
codesign --force --sign - --entitlements "$entitlements" "$output"
printf '%s\n' "$output"
