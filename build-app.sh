#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift_arches=(-c release)
case "${1:-}" in
    "") ;;
    --universal) swift_arches=(-c release --arch arm64 --arch x86_64) ;;
    *) echo "Usage: $0 [--universal]" >&2; exit 2 ;;
esac

bin_dir="$(swift build "${swift_arches[@]}" --show-bin-path)"
swift build "${swift_arches[@]}"

app="dist/Ribbon.app"
mkdir -p dist
stage="$(mktemp -d dist/.ribbon.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Ribbon.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp Support/Info.plist "$bundle/Contents/"
cp Support/Ribbon.icns LICENSE "$bundle/Contents/Resources/"
cp "$bin_dir/Ribbon" "$bundle/Contents/MacOS/"
cp -R "$bin_dir/Ribbon_Ribbon.bundle" "$bundle/Contents/Resources/"
codesign --force --sign - "$bundle"
rm -rf "$app"
mv "$bundle" "$app"
echo "$PWD/$app"
