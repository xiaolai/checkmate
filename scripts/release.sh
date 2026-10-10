#!/bin/bash
# Coordinate an build-host build/sign/package with this Mac's existing notary keychain.
# Source must already be synchronized to CHECKMATE_RELEASE_ROOT on the build host.
set -euo pipefail
cd "$(dirname "$0")/.."
source Version.env
host=${CHECKMATE_RELEASE_HOST:?Set CHECKMATE_RELEASE_HOST to the build-machine SSH alias}
root=${CHECKMATE_RELEASE_ROOT:?Set CHECKMATE_RELEASE_ROOT to the remote repository root}
[[ "$host" =~ ^[a-zA-Z0-9._-]+$ && "$root" =~ ^/[a-zA-Z0-9/._-]+$ ]] || exit 1
CHECKMATE_NOTARY_PROFILE=${CHECKMATE_NOTARY_PROFILE:-chase-notary}
readonly TRIES=5
fail() { echo "error: $*" >&2; exit 1; }
note() { echo "$*"; }
xcrun notarytool history --keychain-profile "$CHECKMATE_NOTARY_PROFILE" --output-format json >/dev/null
mkdir -p build/release
notarize() {  # $1: the file to submit — a .zip of the app, or the .dmg
    local file=$1 attempt out id="" status=""
    for (( attempt = 1; attempt <= TRIES; attempt++ )); do
        if out=$(xcrun notarytool submit "$file" --keychain-profile "$CHECKMATE_NOTARY_PROFILE" \
                    --output-format plist) \
           && id=$(plutil -extract id raw -o - - <<<"$out" 2>/dev/null); then
            break
        fi
        id=""
        (( attempt < TRIES )) || break
        note "upload attempt $attempt of $TRIES did not return a submission id; retrying"
        sleep $(( attempt * 10 ))
    done
    [ -n "$id" ] || fail "could not upload $file for notarisation after $TRIES attempts"
    note "submitted $(basename "$file") as $id; waiting for Apple"

    for (( attempt = 1; attempt <= TRIES; attempt++ )); do
        out=$(xcrun notarytool wait "$id" --keychain-profile "$CHECKMATE_NOTARY_PROFILE" \
                --output-format plist) || true
        status=$(plutil -extract status raw -o - - <<<"$out" 2>/dev/null) || status=""
        case $status in Accepted | Invalid | Rejected) break ;; esac
        (( attempt < TRIES )) || break
        note "no verdict for $id yet (attempt $attempt of $TRIES); asking again — the upload stands"
        sleep $(( attempt * 15 ))
    done
    if [ "$status" != "Accepted" ]; then
        # Apple's log names each rejected file and why; without it a rejection is a guess.
        xcrun notarytool log "$id" --keychain-profile "$CHECKMATE_NOTARY_PROFILE" >&2 || true
        fail "notarisation of $(basename "$file") ended as '${status:-no verdict}' (submission $id)"
    fi
    note "notarised $(basename "$file")"
}

ssh "$host" "cd '$root' && bash scripts/prepare-release.sh"
scp "$host:$root/build/release/Checkmate-$CHECKMATE_VERSION.zip" build/release/
ditto -x -k "build/release/Checkmate-$CHECKMATE_VERSION.zip" build/release/
bash scripts/sign-release.sh build/release/Checkmate.app
ditto -c -k --keepParent build/release/Checkmate.app "build/release/Checkmate-$CHECKMATE_VERSION.zip"
scp "build/release/Checkmate-$CHECKMATE_VERSION.zip" "$host:$root/build/release/"
ssh "$host" "cd '$root' && rm -rf build/release/Checkmate.app && ditto -x -k build/release/Checkmate-$CHECKMATE_VERSION.zip build/release/"
notarize "build/release/Checkmate-$CHECKMATE_VERSION.zip"
ssh "$host" "cd '$root' && bash scripts/finish-release.sh image"
scp "$host:$root/build/release/Checkmate-$CHECKMATE_VERSION.dmg" build/release/
codesign --force --timestamp --sign "${CHECKMATE_SIGN_ID:-Developer ID Application: HANDO K.K. (Y53RSUA3SM)}" "build/release/Checkmate-$CHECKMATE_VERSION.dmg"
notarize "build/release/Checkmate-$CHECKMATE_VERSION.dmg"
scp "build/release/Checkmate-$CHECKMATE_VERSION.dmg" "$host:$root/build/release/"
ssh "$host" "cd '$root' && bash scripts/finish-release.sh verify"
scp "$host:$root/build/release/Checkmate-$CHECKMATE_VERSION.dmg" build/release/
shasum -a 256 "build/release/Checkmate-$CHECKMATE_VERSION.dmg"
