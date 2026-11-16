#!/bin/sh
# Builds "OpenConnect Proxy Login.app" (macOS) from the AppleScript source. Needs only the tools
# that ship with macOS: osacompile, osascript (draws the icon), sips, iconutil, PlistBuddy and
# codesign (ad-hoc signature, no developer account).
# Usage: sh build.sh [output-directory]   (default: dist/ next to this script)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-"$here/dist"}
app="$out/OpenConnect Proxy Login.app"
plist="$app/Contents/Info.plist"

mkdir -p "$out"
rm -rf "$app"
# -s: stay-open applet, so the idle handler runs every minute.
osacompile -s -o "$app" "$here/vpn-login-notifier.applescript"
install -m 0755 "$here/../common/vpn-state.sh" "$app/Contents/Resources/vpn-state.sh"

# App icon instead of the generic AppleScript one: draw it, then build every size into applet.icns.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
osascript -l JavaScript "$here/make-icon.js" "$tmp/icon.png" >/dev/null
mkdir "$tmp/applet.iconset"
for px in 16 32 128 256 512; do
    sips -z "$px" "$px" "$tmp/icon.png" --out "$tmp/applet.iconset/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) "$tmp/icon.png" --out "$tmp/applet.iconset/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns -o "$app/Contents/Resources/applet.icns" "$tmp/applet.iconset"
# The compiled asset catalog holds the AppleScript icon and would take precedence over applet.icns.
rm -f "$app/Contents/Resources/Assets.car"

buddy() { /usr/libexec/PlistBuddy -c "$1" "$plist"; }
buddy 'Delete :CFBundleIdentifier' 2>/dev/null || true
buddy 'Add :CFBundleIdentifier string io.github.matteosecli.openconnect-ocproxy.login-helper'
# The helpers' shared version, plus a build number that changes on every build, so icon and
# notification caches see a new version.
buddy 'Delete :CFBundleShortVersionString' 2>/dev/null || true
buddy "Add :CFBundleShortVersionString string $(cat "$here/../VERSION")"
buddy 'Delete :CFBundleVersion' 2>/dev/null || true
buddy "Add :CFBundleVersion string $(date -u +%Y%m%d.%H%M%S)"
buddy 'Delete :CFBundleIconName' 2>/dev/null || true
buddy 'Delete :LSUIElement' 2>/dev/null || true
buddy 'Add :LSUIElement bool true'   # background app: no Dock icon or menu bar
buddy 'Delete :NSAppleEventsUsageDescription' 2>/dev/null || true
buddy 'Add :NSAppleEventsUsageDescription string Opens your terminal app (Terminal or iTerm2) to run vpn-login when the VPN needs a login.'

# Editing Info.plist invalidates the applet's signature; re-sign ad hoc so macOS will launch it.
codesign --force --deep --sign - "$app"
# Let Finder, Launchpad and Notification Center pick up the new icon.
touch "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" 2>/dev/null || true
echo "Built: $app"
