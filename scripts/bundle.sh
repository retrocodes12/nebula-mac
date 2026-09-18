#!/bin/bash
# Turns the SwiftPM build into Nebula.app, a zip and a dmg under dist/.
#   scripts/bundle.sh [--arch "arm64 x86_64"]
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS="${ARCHS:-arm64 x86_64}"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="${GITHUB_RUN_NUMBER:-1}"
FLAGS=(-c release)
for a in $ARCHS; do FLAGS+=(--arch "$a"); done

swift build "${FLAGS[@]}" --product Nebula
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)"

APP="dist/Nebula.app"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Nebula" "$APP/Contents/MacOS/Nebula"
cp -R Resources/badges "$APP/Contents/Resources/badges"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

# The engine's libraries arrive as frameworks beside the binary. Static ones are already inside
# it; only one the binary actually loads at run time has to ride along inside the app.
shopt -s nullglob
LINKS="$(otool -L "$APP/Contents/MacOS/Nebula")"
for f in "$BIN"/*.framework; do
  name="$(basename "$f" .framework)"
  if echo "$LINKS" | grep -q "/$name.framework/"; then
    mkdir -p "$APP/Contents/Frameworks"
    ditto "$f" "$APP/Contents/Frameworks/$name.framework"
    codesign --force --sign - "$APP/Contents/Frameworks/$name.framework"
    echo "carried: $name"
  fi
done
if [ -d "$APP/Contents/Frameworks" ]; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Nebula" 2>/dev/null || true
fi

# the icon is drawn by the app itself, then cut to the sizes an .icns holds
ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
"$APP/Contents/MacOS/Nebula" --icon "$ICONSET/../icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/../icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); sips -z $d $d "$ICONSET/../icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# no Apple developer account: an ad-hoc signature, which Apple silicon insists on at the least
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

( cd dist && ditto -c -k --keepParent Nebula.app Nebula-mac.zip )
STAGE="$(mktemp -d)"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Nebula" -srcfolder "$STAGE" -ov -format UDZO dist/Nebula.dmg >/dev/null
lipo -archs "$APP/Contents/MacOS/Nebula"
ls -la dist
