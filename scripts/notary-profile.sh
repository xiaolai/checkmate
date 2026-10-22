#!/bin/bash
# Makes the notarytool keychain profile scripts/release.sh notarizes through, from the credentials in `.env`.
#
#   bash scripts/notary-profile.sh [--profile NAME]
#
#   --profile NAME   the keychain profile's name (default CHECKMATE_NOTARY_PROFILE, else chase-notary, what
#                    scripts/release.sh expects).
#
# Why a script: the profile lives in the login keychain and does not survive it — on 2026-10-22 it was gone when the
# release reached notarization, and the credentials exist only in `.env`, which agents never read. This runs the same
# every time: names and the team identifier are printed, values never are.
#
# What it reads, in the order each is tried:
#   the Apple ID    APPLE_ID
#   the password    APP_SPECIFIC_PASSWORD, then APPLE_PASSWORD   (an app-specific password, never the account's)
#   the team        TEAM_ID or APPLE_TEAM_ID if `.env` carries one, else the team of this Mac's Developer ID
#                   Application certificate
#
# It stores nothing unless all three are known, and it asks Apple once (`history`): a profile that cannot be used fails
# here, not after the build host has built the app. `CHECKMATE_ENV_FILE` names another env file (for testing).
# It releases nothing: run scripts/release.sh afterwards (see docs/releases.md).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)

profile=${CHECKMATE_NOTARY_PROFILE:-chase-notary}
while [ $# -gt 0 ]; do
    case $1 in
        --profile) [ $# -ge 2 ] || { echo "notary-profile: --profile needs a name" >&2; exit 2; }
                   profile=$2; shift 2 ;;
        -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
        *) echo "notary-profile: usage: $0 [--profile NAME]" >&2; exit 2 ;;
    esac
done

fail() { echo "notary-profile: $*" >&2; exit 1; }
say() { echo "$*"; }

env_file=${CHECKMATE_ENV_FILE:-$root/.env}
[ -f "$env_file" ] || fail "no env file at $env_file"

# Sourced with `set +u`, so a line that reads another unset variable does not stop the script; the file is the owner's.
set +u
set -a
# shellcheck disable=SC1090 # the path is chosen above, on purpose
. "$env_file"
set +a
set -u

# Names only, never values: what to look at when one is missing below.
names=$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/{printf "%s ", $1}' "$env_file")
pick() {
    local key
    for key in "$@"; do
        if [ -n "${!key:-}" ]; then printf '%s' "${!key}"; return 0; fi
    done
    return 1
}

apple_id=$(pick APPLE_ID) || fail "no APPLE_ID in $env_file (its keys: $names)"
password=$(pick APP_SPECIFIC_PASSWORD APPLE_PASSWORD) \
    || fail "no APP_SPECIFIC_PASSWORD (or APPLE_PASSWORD) in $env_file (its keys: $names)"

team=$(pick TEAM_ID APPLE_TEAM_ID) || team=""
if [ -z "$team" ]; then
    # The certificate's subject carries the team in parentheses: "Developer ID Application: Name (TEAMID)".
    team=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*Developer ID Application: .* (\([A-Z0-9]*\)).*/\1/p' | head -1) || true
fi
[ -n "$team" ] || fail "no team id: TEAM_ID is not in $env_file and this Mac has no Developer ID Application certificate"

say "profile:  $profile"
say "apple id: ${apple_id%%@*}@… (hidden)"
say "team:     $team"

if xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
    say "notary-profile: $profile already works on this Mac; storing it again with the values in $env_file"
fi

xcrun notarytool store-credentials "$profile" \
    --apple-id "$apple_id" --team-id "$team" --password "$password" >/dev/null

unset apple_id password

xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
    || fail "stored, but notarytool cannot use '$profile' — Apple refused or the keychain could not keep it"
say "notary-profile: $profile ready"
