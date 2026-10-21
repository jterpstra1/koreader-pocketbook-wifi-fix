#!/bin/sh
# Build the release zip for a version tag.
#
#   scripts/build-release.sh v0.6.2 [outdir]
#
# The zip mirrors the device's storage root, so it can be extracted straight
# onto the PocketBook: applications/koreader/patches/2-pocketbook-wifi.lua
# (+ its license).
# Also writes the release notes (the tag's CHANGELOG.md section).
set -eu

tag=${1:?usage: build-release.sh vX.Y.Z [outdir]}
root=$(cd "$(dirname "$0")/.." && pwd)
out=${2:-"$root/dist"}
version=${tag#v}
patch="$root/patches/2-pocketbook-wifi.lua"

patch_version=$(sed -n 's/^local PATCH_VERSION = "\(.*\)"$/\1/p' "$patch")
if [ "$patch_version" != "$version" ]; then
    echo "Tag $tag doesn't match PATCH_VERSION \"$patch_version\" in $patch" >&2
    exit 1
fi

notes=$(awk -v v="$version" '
    $0 ~ "^## v?" v "( |$)" { found = 1; next }
    found && /^## / { exit }
    found { print }
' "$root/CHANGELOG.md")
if [ -z "$(printf '%s' "$notes" | tr -d '[:space:]')" ]; then
    echo "No CHANGELOG.md section for $version" >&2
    exit 1
fi

rm -rf "$out"
mkdir -p "$out"
out=$(cd "$out" && pwd) # absolute: zip runs from inside the staging dir
stage="$out/stage"
mkdir -p "$stage/applications/koreader/patches"
# Only the patch (plus its license, which KOReader ignores: not a .lua file),
# so extracting to the device root doesn't leave anything else there.
cp "$patch" "$stage/applications/koreader/patches/"
cp "$root/LICENSE" "$stage/applications/koreader/patches/2-pocketbook-wifi.LICENSE.txt"
zip="$out/koreader-pocketbook-wifi-fix-$tag.zip"
(cd "$stage" && zip -q -r -X "$zip" .)
cp "$patch" "$out/"
printf '%s\n' "$notes" > "$out/release-notes.md"
rm -rf "$stage"

echo "Built $zip"
