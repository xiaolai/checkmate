#!/bin/bash
# Coordinate a build/sign/package on the build host with this Mac's existing notary keychain.
# Source must already be synchronized to CHECKMATE_RELEASE_ROOT on the build host.
set -euo pipefail
# Every Python check here is written with assert: an inherited PYTHONOPTIMIZE would silently skip them all.
unset PYTHONOPTIMIZE
cd "$(dirname "$0")/.."
source Version.env
host=${CHECKMATE_RELEASE_HOST:?Set CHECKMATE_RELEASE_HOST to the build-machine SSH alias}
root=${CHECKMATE_RELEASE_ROOT:?Set CHECKMATE_RELEASE_ROOT to the remote repository root}
# Acceptance evidence and the live-voice report are optional: each is checked when named and warned about when not,
# so a release without them is never silent. CHECKMATE_SKIP_VERIFICATION_REASON, also optional, says why in the warning;
# prepare-release.sh refuses a build that mutates tracked sources either way.
evidence=${CHECKMATE_ACCEPTANCE_EVIDENCE:-} live=${CHECKMATE_LIVE_VOICE_REPORT:-} skip_reason=${CHECKMATE_SKIP_VERIFICATION_REASON:-}
# These go into a single-quoted remote command below; a quote, backtick or $ in them must not reach the shell.
safe_reason='^[A-Za-z0-9 .,:;/_()-]+$'
[[ -z "$skip_reason" || "$skip_reason" =~ $safe_reason ]] || { echo "error: CHECKMATE_SKIP_VERIFICATION_REASON has characters a remote shell could misread; use plain words, digits and .,:;/_()- only" >&2; exit 1; }
[[ "$host" =~ ^[a-zA-Z0-9._-]+$ && "$root" =~ ^/[a-zA-Z0-9/._-]+$ ]] || exit 1
[[ -z "$evidence" || "$evidence" =~ ^/[a-zA-Z0-9/._-]+$ ]] || exit 1
[[ -z "$live" || "$live" =~ ^/[a-zA-Z0-9/._-]+$ ]] || exit 1
[[ -n "$evidence" ]] || echo "WARNING: releasing $CHECKMATE_VERSION without accepted acceptance evidence${skip_reason:+: $skip_reason}" >&2
[[ -n "$live" ]] || echo "WARNING: releasing $CHECKMATE_VERSION without a live-voice report${skip_reason:+: $skip_reason}" >&2
# A release is the tag v<version> exactly: a clean tree at that tag, accepted unchanged on the build host.
[[ -z "$(git status --porcelain)" ]] || { echo "error: the working tree has uncommitted changes" >&2; exit 1; }
commit=$(git rev-parse HEAD)
[[ "$commit" == "$(git rev-parse "v$CHECKMATE_VERSION^{commit}" 2>/dev/null)" ]] || { echo "error: HEAD is not tag v$CHECKMATE_VERSION" >&2; exit 1; }
if [[ -n "$evidence" ]]; then
ssh "$host" "cat '$evidence/acceptance.json'" | python3 scripts/source-hashes.py --compare /dev/stdin --key sourceHashes . \
    || { echo "error: The accepted tree differs from tag sources" >&2; exit 1; }
fi
CHECKMATE_NOTARY_PROFILE=${CHECKMATE_NOTARY_PROFILE:-chase-notary}
identity=${CHECKMATE_SIGN_ID:-Developer ID Application: HANDO K.K. (Y53RSUA3SM)}
readonly TRIES=5
fail() { echo "error: $*" >&2; exit 1; }
note() { echo "$*"; }
xcrun notarytool history --keychain-profile "$CHECKMATE_NOTARY_PROFILE" --output-format json >/dev/null \
    || fail "the notary profile $CHECKMATE_NOTARY_PROFILE does not work; run scripts/notary-profile.sh"
security find-identity -v -p codesigning | grep -qF -- "$identity" || fail "signing identity is not in this keychain: $identity"
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

ssh "$host" "cd '$root' && CHECKMATE_SOURCE_COMMIT='$commit' CHECKMATE_ACCEPTANCE_EVIDENCE='$evidence' CHECKMATE_LIVE_VOICE_REPORT='$live' CHECKMATE_SKIP_VERIFICATION_REASON='$skip_reason' bash scripts/prepare-release.sh"
scp "$host:$root/build/release/Checkmate-$CHECKMATE_VERSION.zip" build/release/
# Extract into a clean generated bundle; ditto merges with existing files.
rm -rf build/release/Checkmate.app
ditto -x -k "build/release/Checkmate-$CHECKMATE_VERSION.zip" build/release/
bash scripts/sign-release.sh build/release/Checkmate.app
ditto -c -k --keepParent build/release/Checkmate.app "build/release/Checkmate-$CHECKMATE_VERSION.zip"
scp "build/release/Checkmate-$CHECKMATE_VERSION.zip" "$host:$root/build/release/"
ssh "$host" "cd '$root' && rm -rf build/release/Checkmate.app && ditto -x -k build/release/Checkmate-$CHECKMATE_VERSION.zip build/release/"
notarize "build/release/Checkmate-$CHECKMATE_VERSION.zip"
ssh "$host" "cd '$root' && bash scripts/finish-release.sh image"
scp "$host:$root/build/release/Checkmate-$CHECKMATE_VERSION.dmg" build/release/
codesign --force --timestamp --sign "$identity" "build/release/Checkmate-$CHECKMATE_VERSION.dmg"
notarize "build/release/Checkmate-$CHECKMATE_VERSION.dmg"
scp "build/release/Checkmate-$CHECKMATE_VERSION.dmg" "$host:$root/build/release/"
rm -f "build/release/Checkmate-$CHECKMATE_VERSION.dmg.verified"
ssh "$host" "cd '$root' && bash scripts/finish-release.sh verify"
# publish-release.sh requires the record of the verified DMG's SHA-256 beside it, so bring both back.
scp "$host:$root/build/release/Checkmate-$CHECKMATE_VERSION.dmg" "$host:$root/build/release/Checkmate-$CHECKMATE_VERSION.dmg.verified" build/release/
shasum -a 256 "build/release/Checkmate-$CHECKMATE_VERSION.dmg"
