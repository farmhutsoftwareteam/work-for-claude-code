#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────────────────────────
# Release pipeline for Work.app (macOS)
# Usage: ./release.sh <version>   e.g. ./release.sh 1.2.0
# ─────────────────────────────────────────────────────────────────────────────

VERSION="$1"
if [ -z "$VERSION" ]; then
    echo "Error: version number required."
    echo "Usage: ./release.sh <version>"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SIGNING_IDENTITY="Developer ID Application: Ryan Katayi (9TUBWSP9WT)"
TEAM_ID="9TUBWSP9WT"
BUNDLE_ID="com.munyamakosa.work"
APP_PATH="build/DerivedData/Build/Products/Release/Work.app"
DMG_NAME="Work.dmg"
ENTITLEMENTS_PATH="/tmp/Work-dist.entitlements"
SPARKLE_PUBKEY="OxlQLub17dx6WhaZ4eF79PE1vfQF+/x4Qo6gt/ThCH0="
APPCAST_URL="https://munyamakosa.github.io/work/appcast.xml"

echo "============================================================"
echo "  Work.app Release Pipeline — v${VERSION}"
echo "============================================================"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Generate Xcode project
# ─────────────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────"
echo "  Step 1: Generating Xcode project with xcodegen"
echo "──────────────────────────────────────────────────────────────"
xcodegen generate
echo "✓ Xcode project generated."
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Build Release
# ─────────────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────"
echo "  Step 2: Building Release configuration"
echo "──────────────────────────────────────────────────────────────"
xcodebuild \
    -project Work.xcodeproj \
    -scheme Work \
    -configuration Release \
    -derivedDataPath build/DerivedData \
    clean build \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual
echo "✓ Build succeeded."
echo ""

# Verify the .app exists
if [ ! -d "$APP_PATH" ]; then
    echo "Error: $APP_PATH not found after build."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Create distribution entitlements
# ─────────────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────"
echo "  Step 3: Creating distribution entitlements"
echo "──────────────────────────────────────────────────────────────"
cat > "$ENTITLEMENTS_PATH" <<'ENTXML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
ENTXML
echo "✓ Distribution entitlements written to $ENTITLEMENTS_PATH"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Re-sign Sparkle framework binaries (deep, inside-out)
# ─────────────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────"
echo "  Step 4: Re-signing Sparkle framework binaries"
echo "──────────────────────────────────────────────────────────────"

SPARKLE_BASE="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"

# Sign innermost first: XPC services (preserve original entitlements)
echo "  Signing Downloader.xpc..."
codesign --force --sign "$SIGNING_IDENTITY" \
    --options runtime --timestamp \
    --preserve-metadata=entitlements \
    "$SPARKLE_BASE/XPCServices/Downloader.xpc"

echo "  Signing Installer.xpc..."
codesign --force --sign "$SIGNING_IDENTITY" \
    --options runtime --timestamp \
    --preserve-metadata=entitlements \
    "$SPARKLE_BASE/XPCServices/Installer.xpc"

# Sign Updater.app (--deep to cover nested binaries)
echo "  Signing Updater.app..."
codesign --force --deep --sign "$SIGNING_IDENTITY" \
    --options runtime --timestamp \
    --preserve-metadata=entitlements \
    "$SPARKLE_BASE/Updater.app"

# Sign Autoupdate
echo "  Signing Autoupdate..."
codesign --force --sign "$SIGNING_IDENTITY" \
    --options runtime --timestamp \
    --preserve-metadata=entitlements \
    "$SPARKLE_BASE/Autoupdate"

# Sign the Sparkle framework itself
echo "  Signing Sparkle.framework..."
codesign --force --sign "$SIGNING_IDENTITY" \
    --options runtime --timestamp \
    --preserve-metadata=entitlements \
    "$APP_PATH/Contents/Frameworks/Sparkle.framework"

echo "✓ Sparkle framework binaries re-signed."
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Re-sign the main .app
# ─────────────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────"
echo "  Step 5: Re-signing Work.app"
echo "──────────────────────────────────────────────────────────────"
codesign --force --sign "$SIGNING_IDENTITY" \
    --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS_PATH" \
    "$APP_PATH"
echo "✓ Work.app re-signed with distribution entitlements."
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Verify code signature
# ─────────────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────"
echo "  Step 6: Verifying code signature"
echo "──────────────────────────────────────────────────────────────"
codesign --verify --deep --strict "$APP_PATH"
echo "✓ Signature verification passed."
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: Create DMG — two-pass so we can drop an /Applications symlink
# alongside Work.app, giving users the standard "drag to install" UX.
# Also applies a Finder window layout (icon positions + background) via
# AppleScript so the DMG opens with the arrow-to-Applications affordance.
# ─────────────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────"
echo "  Step 7: Creating DMG (with drag-to-Applications layout)"
echo "──────────────────────────────────────────────────────────────"

RAW_DMG="/tmp/Work-raw-${VERSION}.dmg"
MOUNT_POINT="/Volumes/Work"

# Defensive cleanup: detach any stale mount, kill any hdiutil helpers still
# holding the volume, and drop prior artifacts.
hdiutil detach "$MOUNT_POINT" -force 2>/dev/null || true
hdiutil info | grep -B2 "Work.dmg" | grep -E '^/dev/disk' | awk '{print $1}' | while read -r dev; do
    hdiutil detach "$dev" -force 2>/dev/null || true
done
rm -f "$RAW_DMG" "$DMG_NAME"

# Size the read-write DMG to the app plus ~30MB headroom
APP_SIZE_MB=$(du -sm "$APP_PATH" | awk '{print $1}')
RAW_SIZE_MB=$((APP_SIZE_MB + 30))

# 1. Create an EMPTY writable DMG (no -srcfolder — that would trigger
#    hdiutil's implicit mount-during-create, which hits "Operation not
#    permitted" on macs where /Volumes/ writes are restricted).
#    -format UDRW requires a source on newer macOS; omitting -format
#    produces a writable UDIF by default which we convert to UDZO later.
hdiutil create \
    -volname "Work" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -size "${RAW_SIZE_MB}m" \
    "$RAW_DMG"

# 2. Attach it. Prefer /Volumes/Work (Finder-visible, required by AppleScript
#    styling). Fall back to a /tmp mount if macOS TCC denies /Volumes/ writes
#    (e.g. when running from a sandboxed shell without Full Disk Access) —
#    we still produce a functional DMG, just without the window layout.
FANCY_LAYOUT=1
DEVICE=$(hdiutil attach "$RAW_DMG" \
    -mountpoint "$MOUNT_POINT" \
    -readwrite -noverify -noautoopen \
    | egrep '^/dev/' | sed 1q | awk '{print $1}')

# Probe /Volumes/Work for writability. Some macs allow touch / mkdir under
# TCC but block ditto's xattr-preserving copy of a signed .app bundle —
# so we don't just touch, we mkdir + ditto-copy a tiny test file. This is
# closer to the actual operation that fails on TCC-restricted shells.
PROBE_DIR="$MOUNT_POINT/.write-probe"
PROBE_SRC="/tmp/work-dmg-probe.txt"
echo "probe" > "$PROBE_SRC"
if mkdir -p "$PROBE_DIR" 2>/dev/null && ditto "$PROBE_SRC" "$PROBE_DIR/probe.txt" 2>/dev/null; then
    rm -rf "$PROBE_DIR" "$PROBE_SRC"
else
    echo "  ⚠ /Volumes/Work doesn't accept ditto writes (TCC). Falling back to"
    echo "    /tmp mount. The DMG will ship without Finder window styling."
    echo "    For the full layout, run this from a Terminal with Full Disk Access."
    rm -f "$PROBE_SRC"
    hdiutil detach "$DEVICE" -force 2>/dev/null || true
    MOUNT_POINT="/tmp/work-dmg-mount-${VERSION}"
    mkdir -p "$MOUNT_POINT"
    DEVICE=$(hdiutil attach "$RAW_DMG" \
        -mountpoint "$MOUNT_POINT" \
        -nobrowse -readwrite -noverify -noautoopen \
        | egrep '^/dev/' | sed 1q | awk '{print $1}')
    FANCY_LAYOUT=0
fi

# 3. Copy the app in. `ditto` preserves HFS metadata + symlinks + xattrs
#    cleanly, unlike plain cp.
ditto "$APP_PATH" "$MOUNT_POINT/Work.app"

# 4. Drop an /Applications symlink next to Work.app so users can drag across
ln -s /Applications "$MOUNT_POINT/Applications"

# 5. Copy the background TIFF into a hidden .background folder inside the DMG.
# Finder picks it up via the AppleScript that follows.
if [ -f "$SCRIPT_DIR/resources/dmg-background.tiff" ]; then
    mkdir -p "$MOUNT_POINT/.background"
    cp "$SCRIPT_DIR/resources/dmg-background.tiff" "$MOUNT_POINT/.background/background.tiff"
    BG_AVAILABLE=1
else
    echo "  ⚠ resources/dmg-background.tiff not found — DMG will ship without the drag-arrow background"
    echo "    Run: python3 scripts/build-dmg-background.py && tiffutil -cathidpicheck resources/dmg-background.png resources/dmg-background@2x.png -out resources/dmg-background.tiff"
    BG_AVAILABLE=0
fi

# 6. Tell Finder where to put the icons + set the window background.
# Only meaningful when mounted at /Volumes/Work where Finder can see it.
# Skipped gracefully if Finder automation is denied OR if we fell back
# to the /tmp mount (Finder doesn't see non-/Volumes mounts).
if [ "$FANCY_LAYOUT" -eq 0 ]; then
    echo "  (skipping Finder window layout — not mounted at /Volumes/)"
elif [ "$BG_AVAILABLE" -eq 1 ]; then
    osascript <<EOF || true
tell application "Finder"
    tell disk "Work"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 100, 900, 430}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 12
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "Work.app" of container window to {130, 150}
        set position of item "Applications" of container window to {370, 150}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
else
    osascript <<EOF || true
tell application "Finder"
    tell disk "Work"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 100, 900, 430}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set position of item "Work.app" of container window to {130, 150}
        set position of item "Applications" of container window to {370, 150}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
fi

# 7. Flush + unmount
sync
hdiutil detach "$DEVICE" -quiet

# 8. Convert to compressed read-only UDZO for distribution
hdiutil convert "$RAW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_NAME"
rm -f "$RAW_DMG"
echo "✓ $DMG_NAME created with drag-to-Applications layout."
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 8: Notarize DMG
# ─────────────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────"
echo "  Step 8: Notarizing DMG (this may take a few minutes)"
echo "──────────────────────────────────────────────────────────────"
NOTARY_OUTPUT=$(xcrun notarytool submit "$DMG_NAME" \
    --apple-id "munya@munyamakosa.com" \
    --team-id "$TEAM_ID" \
    --keychain-profile "notary-profile" \
    --wait --output-format json)

NOTARY_STATUS=$(echo "$NOTARY_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
if [ "$NOTARY_STATUS" != "Accepted" ]; then
    echo "Error: Notarization failed with status: $NOTARY_STATUS"
    echo "$NOTARY_OUTPUT"
    exit 1
fi
echo "✓ Notarization accepted."
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 9: Staple notarization ticket
# ─────────────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────"
echo "  Step 9: Stapling notarization ticket"
echo "──────────────────────────────────────────────────────────────"
xcrun stapler staple "$DMG_NAME"
echo "✓ Notarization ticket stapled to $DMG_NAME."
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 10: Generate Sparkle appcast entry
# ─────────────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────"
echo "  Step 10: Generating Sparkle appcast entry"
echo "──────────────────────────────────────────────────────────────"

DMG_SIZE=$(stat -f%z "$DMG_NAME")
PUBLISH_DATE=$(date -R)
DOWNLOAD_URL="https://munyamakosa.github.io/work/$DMG_NAME"

# Attempt EdDSA signature
EDDSA_SIG=""
SIGN_UPDATE_BIN=""

# Check common locations for sign_update
for candidate in \
    "$SCRIPT_DIR/sparkle/bin/sign_update" \
    "$SCRIPT_DIR/Sparkle/bin/sign_update" \
    "$HOME/Library/Frameworks/Sparkle.framework/Resources/sign_update" \
    "/usr/local/bin/sign_update"; do
    if [ -x "$candidate" ]; then
        SIGN_UPDATE_BIN="$candidate"
        break
    fi
done

if [ -n "$SIGN_UPDATE_BIN" ]; then
    echo "  Found sign_update at: $SIGN_UPDATE_BIN"
    echo "  Generating EdDSA signature..."
    EDDSA_SIG=$("$SIGN_UPDATE_BIN" "$DMG_NAME" 2>&1 | grep -oE 'sparkle:edSignature="[^"]+"' | sed 's/sparkle:edSignature="//' | sed 's/"$//' || true)
    if [ -n "$EDDSA_SIG" ]; then
        echo "  ✓ EdDSA signature generated."
    else
        # Some versions output just the signature
        EDDSA_SIG=$("$SIGN_UPDATE_BIN" "$DMG_NAME" 2>&1 || true)
        EDDSA_SIG=$(echo "$EDDSA_SIG" | tr -d '\n' | xargs)
        if [ -n "$EDDSA_SIG" ]; then
            echo "  ✓ EdDSA signature generated."
        else
            echo "  ⚠ Could not parse EdDSA signature. You will need to sign manually."
        fi
    fi
else
    echo "  ⚠ sign_update not found. You will need to generate the EdDSA signature manually."
    echo "    Run: sparkle/bin/sign_update $DMG_NAME"
fi

echo ""
echo "  ── Appcast XML snippet ──"
echo ""

if [ -n "$EDDSA_SIG" ]; then
    EDDSA_ATTR="sparkle:edSignature=\"$EDDSA_SIG\""
else
    EDDSA_ATTR="sparkle:edSignature=\"REPLACE_WITH_EDDSA_SIGNATURE\""
fi

APPCAST_SNIPPET=$(cat <<XMLEOF
<item>
    <title>Version ${VERSION}</title>
    <pubDate>${PUBLISH_DATE}</pubDate>
    <sparkle:version>${VERSION}</sparkle:version>
    <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
    <enclosure
        url="${DOWNLOAD_URL}"
        length="${DMG_SIZE}"
        type="application/octet-stream"
        ${EDDSA_ATTR}
    />
</item>
XMLEOF
)

echo "$APPCAST_SNIPPET"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 11: Create the GitHub release (tag + notes + DMG asset)
# Reads notes from release-notes/v${VERSION}.md. The file's expected to exist
# before this step — write it alongside the version bump in project.yml so the
# release flow has the full body to hand to `gh release create`. If absent,
# we print the exact command to run later instead of failing the build.
# ─────────────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────"
echo "  Step 11: Creating GitHub release"
echo "──────────────────────────────────────────────────────────────"

NOTES_FILE="$SCRIPT_DIR/release-notes/v${VERSION}.md"
TAG="v${VERSION}"
GH_TITLE="Work ${VERSION}"

if ! command -v gh &>/dev/null; then
    echo "  ⚠ gh CLI not installed — skipping. Install with: brew install gh"
    echo "    After installing, run:"
    echo "      gh release create $TAG --title \"$GH_TITLE\" --notes-file $NOTES_FILE $DMG_NAME"
elif [ ! -f "$NOTES_FILE" ]; then
    echo "  ⚠ Release notes not found at $NOTES_FILE"
    echo "    Write the body for this release there (markdown), then run:"
    echo "      gh release create $TAG --title \"$GH_TITLE\" --notes-file $NOTES_FILE $DMG_NAME"
elif gh release view "$TAG" &>/dev/null; then
    # Release already exists (re-running release.sh on the same version):
    # just refresh the DMG asset so users get the freshest binary.
    echo "  ⚠ GitHub release $TAG already exists — replacing the DMG asset only."
    gh release upload "$TAG" "$DMG_NAME" --clobber
    echo "✓ Re-uploaded $DMG_NAME to existing release $TAG."
else
    # `gh release create` creates the git tag at the current HEAD if it
    # doesn't exist locally. Make sure your version-bump commit is the tip
    # of the branch before running this — otherwise the tag will point at
    # an older commit.
    gh release create "$TAG" \
        --title "$GH_TITLE" \
        --notes-file "$NOTES_FILE" \
        "$DMG_NAME"
    echo "✓ GitHub release $TAG created with $DMG_NAME attached."
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
echo "============================================================"
echo "  Release v${VERSION} complete!"
echo "============================================================"
echo ""
echo "Artifacts:"
echo "  • $DMG_NAME ($(du -h "$DMG_NAME" | cut -f1) — notarized & stapled)"
echo ""
echo "Next steps:"
echo "  1. Add the appcast XML snippet above to docs/appcast.xml"
echo "  2. Re-run scripts/build-releases.js to regenerate docs/releases.html"
echo "  3. Copy $DMG_NAME into docs/, then 'cd docs && vercel --prod --yes'"
echo "  4. git commit + push the version bump, appcast, releases.html, and"
echo "     release-notes/v${VERSION}.md"
echo "  5. If the GH release step skipped above, run the command it printed"
echo ""
echo "────────────────────────────────────────────────────────────"
echo "  Keychain Profile Setup (one-time)"
echo "────────────────────────────────────────────────────────────"
echo ""
echo "If you haven't stored your notarization credentials yet, run:"
echo ""
echo "  xcrun notarytool store-credentials \"notary-profile\" \\"
echo "      --apple-id \"munya@munyamakosa.com\" \\"
echo "      --team-id \"9TUBWSP9WT\" \\"
echo "      --password \"APP_SPECIFIC_PASSWORD\""
echo ""
echo "Replace APP_SPECIFIC_PASSWORD with an app-specific password"
echo "generated at https://appleid.apple.com/account/manage"
echo ""
