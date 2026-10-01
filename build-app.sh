#!/bin/zsh
# Bygger "Vinyl Shelf Finder.app" i ./build (release-build, ad-hoc signeret).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product VinylShelfFinder
BIN="$(swift build -c release --show-bin-path)/VinylShelfFinder"

APP="build/Vinyl Shelf Finder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VinylShelfFinder"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Signering: med et fast, selvlavet udviklercertifikat ("Vinyl Shelf Finder Udvikler")
# husker macOS "Tillad altid" til nøgleringen på tværs af nye versioner. Uden det bruges
# ad-hoc-signering, og så spørger macOS igen efter hver ny build.
IDENTITY="Vinyl Shelf Finder Udvikler"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    codesign --force --sign "$IDENTITY" --identifier dk.vinylshelffinder.app "$APP" >/dev/null
    echo "✓ Signeret med \"$IDENTITY\""
else
    codesign --force --sign - "$APP" >/dev/null
fi

APP="$PWD/$APP"
echo "✓ Bygget: $APP"

# ./build-app.sh --install lægger også den nye version i Programmer (/Applications).
if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/Vinyl Shelf Finder.app"
    ditto "$APP" "/Applications/Vinyl Shelf Finder.app"
    echo "✓ Installeret: /Applications/Vinyl Shelf Finder.app (luk appen med ⌘Q og åbn den igen)"
    exit 0
fi

echo "  Åbn:        open \"$APP\""
echo "  Demo-data:  open \"$APP\" --args --demo"
echo "  Installér:  cp -R \"$APP\" /Applications/"
