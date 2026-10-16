#!/bin/bash
# Builds Tools/lan-spike.swift into LanSpike.app, so the spike runs as an app launched by LaunchServices in the Aqua
# session: a process started from SSH is exempt from local-network privacy and would prove nothing.
#   bash Tools/lan-spike.sh <output-dir> [signing-identity] [keychain]
# CHECKMATE_SPIKE_TARGET (e.g. arm64-apple-macos14) builds it for an older system, to run in a virtual machine.
# Without an identity the bundle is signed ad hoc, whose signature changes with every build.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/test_host.py "the LAN spike" || exit 1
output=${1:?Usage: lan-spike.sh <output-dir> [signing-identity] [keychain]}
app="$output/LanSpike.app/Contents"
rm -rf "$output/LanSpike.app"
mkdir -p "$app/MacOS"
xcrun swiftc -O ${CHECKMATE_SPIKE_TARGET:+-target $CHECKMATE_SPIKE_TARGET} Tools/lan-spike.swift -o "$app/MacOS/lan-spike"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleExecutable</key><string>lan-spike</string><key>CFBundleIdentifier</key><string>ai.xiaolai.checkmate.lan-spike</string><key>CFBundleName</key><string>LanSpike</string><key>CFBundleVersion</key><string>1</string><key>LSUIElement</key><true/><key>NSLocalNetworkUsageDescription</key><string>Checkmate finds and connects to games on your local network</string><key>NSBonjourServices</key><array><string>_checkmate-auto._tcp</string></array></dict></plist>
PLIST
if [[ -n "${2:-}" ]]; then
  codesign --force --sign "$2" ${3:+--keychain "$3"} "$output/LanSpike.app"
else
  codesign --force --sign - "$output/LanSpike.app"
fi
codesign --verify --strict "$output/LanSpike.app"
printf '%s\n' "$output/LanSpike.app"
