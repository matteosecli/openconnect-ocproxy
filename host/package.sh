#!/bin/sh
# Builds the login helpers' release files into an output directory (default: host/release/):
#   openconnect-ocproxy-helper-<version>-macos.zip     the macOS app
#   openconnect-ocproxy-helper-<version>-linux.tar.gz  the Linux service and installer
#   SHA256SUMS
# The version comes from host/VERSION. Needs macOS (the app is compiled with osacompile); the
# "Helpers release" workflow runs this on a macOS runner.
# Usage: sh host/package.sh [output-directory]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
version=$(cat "$here/VERSION")
case $version in
    '' | *[!0-9.]* | .* | *.) echo "Unexpected version in $here/VERSION: '$version'" >&2; exit 1 ;;
esac
out=${1:-"$here/release"}
name=openconnect-ocproxy-helper-$version
zip=$name-macos.zip
tgz=$name-linux.tar.gz

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out"
rm -f "$out/$zip" "$out/$tgz" "$out/SHA256SUMS"

# macOS app. Its only native code is the applet stub that osacompile copies from the system,
# which is a universal binary; check it still is, so the app runs on Intel and Apple silicon.
sh "$here/macos/build.sh" "$tmp/mac"
app="$tmp/mac/OpenConnect Proxy Login.app"
codesign --verify --strict --deep "$app"
archs=$(lipo -archs "$app/Contents/MacOS/applet")
for arch in x86_64 arm64; do
    case " $archs " in
        *" $arch "*) ;;
        *) echo "The applet is built for '$archs' only; $arch is missing." >&2; exit 1 ;;
    esac
done
app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[ "$app_version" = "$version" ] || { echo "App version $app_version != $version" >&2; exit 1; }
# ditto keeps the bundle intact, so the ad-hoc signature still verifies after unzipping.
ditto -c -k --keepParent "$app" "$out/$zip"

# Linux: VERSION, common/ and linux/ under a versioned top folder, owned by root, without macOS
# metadata (extended attributes, ._ files).
tar -czf "$out/$tgz" --no-xattrs --no-mac-metadata --exclude .DS_Store \
    --uid 0 --gid 0 --uname root --gname root -s ",^,$name-linux/," \
    -C "$here" VERSION common linux

(cd "$out" && shasum -a 256 "$zip" "$tgz" > SHA256SUMS)
echo "Built helpers $version (app: $archs) in $out:"
ls -l "$out/$zip" "$out/$tgz" "$out/SHA256SUMS"
