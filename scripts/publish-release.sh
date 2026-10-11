#!/bin/bash
# Publish a verified release from the coordinating Mac: after scripts/release.sh has produced the stapled DMG.
# Creates the GitHub release for tag v<version> with the DMG, the tag's source archive and SHA256SUMS, then
# dispatches .github/workflows/update-homebrew.yml so the xiaolai/tap cask follows.
# Outward-facing: run it only to publish. It refuses anything but a clean tree checked out at the release tag.
set -euo pipefail
cd "$(dirname "$0")/.."
source Version.env
version=$CHECKMATE_VERSION tag="v$CHECKMATE_VERSION" out=build/release
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: Version.env must hold a stable X.Y.Z version" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: the working tree has uncommitted changes" >&2; exit 1; }
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "$tag^{commit}" 2>/dev/null)" ]] || { echo "error: HEAD is not tag $tag" >&2; exit 1; }
dmg="$out/Checkmate-$version.dmg"
[[ -s "$dmg" ]] || { echo "error: $dmg is missing; run scripts/release.sh first" >&2; exit 1; }
xcrun stapler validate "$dmg"
# A valid ticket is not final verification: finish-release.sh verify records the SHA-256 of the DMG it fully checked.
[[ -s "$dmg.verified" && "$(awk '{print $1}' "$dmg.verified")" == "$(shasum -a 256 "$dmg" | awk '{print $1}')" ]] || { echo "error: $dmg has not passed scripts/finish-release.sh verify in its current form" >&2; exit 1; }
commit=$(git rev-parse HEAD)
# A valid ticket says nothing about what the image holds: the app inside must be this version, build and commit.
mount=$(mktemp -d);notes=$(mktemp);trap 'hdiutil detach -quiet "$mount" 2>/dev/null || true;rm -rf "$mount" "$notes"' EXIT
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount" "$dmg"
plist="$mount/Checkmate.app/Contents/Info.plist"
for pair in "CFBundleShortVersionString=$version" "CFBundleVersion=$CHECKMATE_BUILD_NUMBER" "CheckmateSourceCommit=$commit"; do
  found=$(/usr/libexec/PlistBuddy -c "Print :${pair%%=*}" "$plist" 2>/dev/null || true)
  [[ "$found" == "${pair#*=}" ]] || { echo "error: the DMG's app has ${pair%%=*} '$found', expected '${pair#*=}'" >&2; exit 1; }
done
hdiutil detach -quiet "$mount"
# The GitHub tag must already exist and name this commit; never let the release create it from the default branch.
remote=$(git ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}" | awk '{print $1}' | tail -1)
[[ "$remote" == "$commit" ]] || { echo "error: origin's $tag is '${remote:-missing}', not $commit; push the tag first" >&2; exit 1; }
# The source archive comes from the tag itself, never from the working tree.
git archive --format=tar.gz --prefix="checkmate-$version/" -o "$out/Checkmate-$version-source.tar.gz" "$tag"
(cd "$out" && shasum -a 256 "Checkmate-$version.dmg" "Checkmate-$version-source.tar.gz" > SHA256SUMS)
# CHANGELOG.md sections are "# Checkmate <version>".
awk -v v="$version" '$0 == "# Checkmate "v {found=1;next} found && /^# Checkmate / {exit} found {print}' CHANGELOG.md > "$notes"
[[ -s "$notes" ]] || { echo "error: CHANGELOG.md has no section for $version" >&2; exit 1; }
gh release create "$tag" --repo xiaolai/checkmate --verify-tag --title "Checkmate $version" --notes-file "$notes" \
  "$dmg" "$out/Checkmate-$version-source.tar.gz" "$out/SHA256SUMS"
gh workflow run update-homebrew.yml --repo xiaolai/checkmate -f version="$version"
echo "Published $tag; the Homebrew tap update is running."
