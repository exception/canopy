#!/bin/zsh
# Builds a release of Canopy and packages it as a drag-to-install DMG with a Sparkle appcast.
#
#   scripts/release.sh                          # version from project.yml
#   scripts/release.sh --publish notes.md       # ...and create the GitHub release
#
# Updates: the app checks the appcast.xml attached to the latest GitHub release
# (SUFeedURL in Resources/Info.plist). This script signs the DMG with the Sparkle EdDSA key
# stored in your login keychain under the account "canopy" (made once with
# `generate_keys --account canopy`; never commit it) and writes build/release/appcast.xml.
# Attach both files to every release, or installed copies stop seeing updates.
# CURRENT_PROJECT_VERSION in project.yml must go up every release: Sparkle compares it.
#
# Signing: first "Developer ID Application" identity in the keychain (or $SIGN_ID). Without one
# the app is ad-hoc signed and only runs without warnings on this Mac.
# Notarization: if a notarytool keychain profile named $NOTARY_PROFILE (default "canopy-notary")
# exists, the app and DMG are notarized and stapled.
set -euo pipefail
cd "${0:A:h}/.."
PUBLISH=0; NOTES=""
if [[ ${1:-} == --publish ]]; then
  PUBLISH=1; NOTES=${2:-}
  [[ -f $NOTES ]] || { echo "usage: $0 --publish <release-notes.md>"; exit 1; }
  cp "$NOTES" "${TMPDIR:-/tmp}/canopy-release-notes.md"; NOTES="${TMPDIR:-/tmp}/canopy-release-notes.md"
fi
unset PITWALL_SOCKET PITWALL_TILE_ID PITWALL_BOARD_ID PITWALL_SESSION_ID PITWALL_CLI
VERSION=$(awk -F'"' '/MARKETING_VERSION/{print $2; exit}' project.yml)
BUILD=$(awk -F'"' '/CURRENT_PROJECT_VERSION/{print $2; exit}' project.yml)
REPO=${CANOPY_REPO:-exception/canopy}
OUT=build/release
DD=build/rel
APP=$DD/Build/Products/Release/Canopy.app
NOTARY_PROFILE=${NOTARY_PROFILE:-canopy-notary}
# Same Apple team as Pitwall: reuse its notary profile when Canopy has none of its own.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
   && xcrun notarytool history --keychain-profile pitwall-notary >/dev/null 2>&1; then NOTARY_PROFILE=pitwall-notary; fi
SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}
SIGN_ID=${SIGN_ID:--}

echo "==> Canopy $VERSION ($BUILD), signing: ${SIGN_ID}"
rm -rf $OUT && mkdir -p $OUT
xcodegen generate >/dev/null

echo "==> Building (Release, arm64)"
xcodebuild -project Canopy.xcodeproj -scheme Canopy -configuration Release -derivedDataPath $DD \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build | grep -E "error:|\*\* BUILD" || true
[[ -d $APP ]] || { echo "build failed"; exit 1; }

echo "==> Signing"
TS=(); [[ $SIGN_ID != "-" ]] && TS=(--timestamp)
# Loose dylibs Xcode embeds (e.g. libswiftCompatibilitySpan) need the Developer ID too.
for lib in $APP/Contents/Frameworks/*.dylib(N); do
  codesign --force --sign "$SIGN_ID" --options runtime $TS "$lib"
done
# Sparkle's helpers are nested code: sign them inside-out before the app.
SPK=$APP/Contents/Frameworks/Sparkle.framework/Versions/B
codesign --force --sign "$SIGN_ID" --options runtime $TS "$SPK/XPCServices/Installer.xpc"
codesign --force --sign "$SIGN_ID" --options runtime $TS --preserve-metadata=entitlements "$SPK/XPCServices/Downloader.xpc"
codesign --force --sign "$SIGN_ID" --options runtime $TS "$SPK/Autoupdate"
codesign --force --sign "$SIGN_ID" --options runtime $TS "$SPK/Updater.app"
codesign --force --sign "$SIGN_ID" --options runtime $TS "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$SIGN_ID" --options runtime $TS --entitlements Resources/Canopy.entitlements "$APP"
codesign --verify --strict --deep "$APP"

CAN_NOTARIZE=0
if [[ $SIGN_ID != "-" ]] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then CAN_NOTARIZE=1; fi
if (( CAN_NOTARIZE )); then
  echo "==> Notarizing the app"
  ditto -c -k --keepParent "$APP" $OUT/Canopy.zip
  xcrun notarytool submit $OUT/Canopy.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm $OUT/Canopy.zip
fi

echo "==> Making the DMG"
STAGE=$OUT/stage
mkdir -p $STAGE/.background
ditto "$APP" $STAGE/Canopy.app
ln -s /Applications $STAGE/Applications
[[ -x build/dmg-background && build/dmg-background -nt scripts/tools/dmg-background.swift ]] || swiftc -O scripts/tools/dmg-background.swift -o build/dmg-background
build/dmg-background $STAGE/.background >/dev/null
tiffutil -cathidpicheck $STAGE/.background/background.png $STAGE/.background/background@2x.png -out $STAGE/.background/background.tiff >/dev/null 2>&1
rm $STAGE/.background/background*.png
RW=$OUT/rw.dmg
hdiutil create -srcfolder $STAGE -volname "Canopy" -fs HFS+ -format UDRW -ov $RW >/dev/null 2>&1
MNT=$(hdiutil attach -readwrite -noverify -noautoopen $RW | awk -F'\t' '/\/Volumes\//{print $NF}')
# Window layout: 660×400, big icons, app on the left, Applications on the right.
osascript <<OSA
tell application "Finder"
  tell disk "Canopy"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Canopy.app" of container window to {165, 200}
    set position of item "Applications" of container window to {495, 200}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
SetFile -a V "$MNT/.background" 2>/dev/null || true
sync; hdiutil detach "$MNT" >/dev/null
DMG=$OUT/Canopy-$VERSION.dmg
hdiutil convert $RW -format UDZO -imagekey zlib-level=9 -o $DMG >/dev/null
rm -f $RW; rm -rf $STAGE
[[ $SIGN_ID != "-" ]] && codesign --force --sign "$SIGN_ID" $TS $DMG
if (( CAN_NOTARIZE )); then
  echo "==> Notarizing the DMG"
  xcrun notarytool submit $DMG --keychain-profile "$NOTARY_PROFILE" --wait && xcrun stapler staple $DMG
fi
echo "==> $DMG ($(du -h $DMG | cut -f1))"
if [[ $SIGN_ID == "-" ]]; then
  echo "    Ad-hoc signed: fine on this Mac, blocked by Gatekeeper elsewhere. Needs a Developer ID to ship."
elif (( ! CAN_NOTARIZE )); then
  echo "    Signed but not notarized: other Macs will warn. Set up '$NOTARY_PROFILE' with xcrun notarytool store-credentials."
fi

echo "==> Writing the appcast"
SIGN_UPDATE=$DD/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
ED=$($SIGN_UPDATE --account canopy $DMG) || { echo "sign_update failed: is the 'canopy' Sparkle key in this keychain? (generate_keys --account canopy)"; exit 1; }
NOTES_HTML=""
if [[ -n $NOTES ]]; then
  NOTES_HTML=$(gh api -X POST /markdown -f mode=gfm -f context=$REPO -F text=@$NOTES)
fi
cat > $OUT/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Canopy</title>
    <item>
      <title>Canopy $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <description><![CDATA[$NOTES_HTML]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/Canopy-$VERSION.dmg" type="application/octet-stream" $ED />
    </item>
  </channel>
</rss>
XML
echo "==> $OUT/appcast.xml"

if (( PUBLISH )); then
  echo "==> Publishing v$VERSION"
  if gh release view v$VERSION -R $REPO >/dev/null 2>&1; then
    # Re-running a version (e.g. after fixing signing) replaces its files instead of failing.
    gh release upload v$VERSION $DMG $OUT/appcast.xml -R $REPO --clobber
    gh release edit v$VERSION -R $REPO --notes-file $NOTES
  else
    gh release create v$VERSION $DMG $OUT/appcast.xml -R $REPO --title "Canopy $VERSION" --notes-file $NOTES
  fi
else
  echo "    Publish with: gh release create v$VERSION $DMG $OUT/appcast.xml -R $REPO --title \"Canopy $VERSION\" --notes-file <notes.md>"
fi
