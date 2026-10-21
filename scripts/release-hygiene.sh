#!/bin/bash
# Keep only the most recent release, everywhere: run it after every published release.
# It removes, for every version but Version.env's:
#   - the GitHub release with its assets, and its v<version> tag on origin and here;
#   - build/release/Checkmate-<version>* on this Mac;
#   - ~/Developer/checkmate-release-<version>* on each host in CHECKMATE_HYGIENE_HOSTS (space-separated SSH aliases).
# It refuses unless the current version is already published and marked Latest, so it can never leave no release.
# Dry run by default: it prints what it would remove. Pass --apply to remove it. Deletions on GitHub are permanent.
set -euo pipefail
cd "$(dirname "$0")/.."
source Version.env
apply=false
case "${1:-}" in --apply) apply=true;; "") ;; *) echo "usage: scripts/release-hygiene.sh [--apply]" >&2; exit 2;; esac
repo=xiaolai/checkmate version=$CHECKMATE_VERSION keep="v$CHECKMATE_VERSION"
semver='^v[0-9]+\.[0-9]+\.[0-9]+$'
[[ "$keep" =~ $semver ]] || { echo "error: Version.env must hold a stable X.Y.Z version" >&2; exit 1; }
hosts=${CHECKMATE_HYGIENE_HOSTS-}
for host in $hosts; do [[ "$host" =~ ^[a-zA-Z0-9._-]+$ ]] || { echo "error: bad host alias '$host'" >&2; exit 1; }; done
latest=$(gh release view --repo "$repo" --json tagName -q .tagName)
[[ "$latest" == "$keep" ]] || { echo "error: GitHub's latest release is '$latest', not $keep; publish $keep first" >&2; exit 1; }
[[ -s "build/release/Checkmate-$version.dmg" ]] || echo "note: build/release/Checkmate-$version.dmg is not on this Mac"

run() { if $apply; then echo "+ $*"; "$@"; else echo "would: $*"; fi; }
releases=$(gh release list --repo "$repo" --limit 1000 --json tagName -q '.[].tagName')
remote_tags=$(git ls-remote --tags origin | awk '$2 !~ /\^\{\}$/ {sub("refs/tags/","",$2); print $2}')
local_tags=$(git tag -l 'v*')
removed=0
for tag in $releases; do [[ "$tag" != "$keep" ]] || continue
  # --cleanup-tag also deletes the tag on origin.
  run gh release delete "$tag" --repo "$repo" --yes --cleanup-tag; removed=$((removed+1))
done
for tag in $remote_tags; do [[ "$tag" =~ $semver && "$tag" != "$keep" ]] || continue
  grep -qxF "$tag" <<<"$releases" && continue
  run git push origin --delete "refs/tags/$tag"; removed=$((removed+1))
done
for tag in $local_tags; do [[ "$tag" =~ $semver && "$tag" != "$keep" ]] || continue
  run git tag -d "$tag"; removed=$((removed+1))
done
shopt -s nullglob
for path in build/release/Checkmate-[0-9]*; do
  [[ "$(basename "$path")" == Checkmate-"$version"[.-]* ]] && continue
  run rm -rf "$path"; removed=$((removed+1))
done
for host in $hosts; do
  found=$(ssh "$host" "find ~/Developer -maxdepth 1 -name 'checkmate-release-[0-9]*' -exec basename {} ';'")
  for path in $found; do [[ "$path" =~ ^checkmate-release-[0-9][0-9A-Za-z._-]*$ ]] || { echo "error: unexpected name '$path' on $host" >&2; exit 1; }
    [[ "$path" == "checkmate-release-$version" || "$path" == checkmate-release-"$version"[.-]* ]] && continue
    run ssh "$host" "rm -rf ~/Developer/$path"; removed=$((removed+1))
  done
done
$apply && echo "Kept $keep; removed $removed item(s)." || echo "Dry run: $removed item(s) would go. Pass --apply to remove them."
