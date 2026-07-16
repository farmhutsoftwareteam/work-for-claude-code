#!/bin/bash
set -eo pipefail

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

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: version must be MAJOR.MINOR.PATCH (received: $VERSION)."
    exit 1
fi

PROJECT_VERSION=$(grep -E "^  MARKETING_VERSION:" project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
if [ "$PROJECT_VERSION" != "$VERSION" ]; then
    echo "Error: project.yml MARKETING_VERSION is $PROJECT_VERSION, not $VERSION."
    exit 1
fi

NOTES_FILE="$SCRIPT_DIR/release-notes/v${VERSION}.md"
if [ ! -s "$NOTES_FILE" ]; then
    echo "Error: release notes are required at $NOTES_FILE."
    exit 1
fi
if [ ! -d "$SCRIPT_DIR/docs" ]; then
    echo "Error: docs/ is required so the exact signed DMG can be staged."
    exit 1
fi
for tool in git xcodegen xcodebuild codesign xcrun hdiutil gh; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: required release tool '$tool' is not installed."
        exit 1
    fi
done
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
    echo "Error: release from a clean, committed worktree so the tag identifies the exact source."
    git status --short
    exit 1
fi
if ! git symbolic-ref -q HEAD >/dev/null; then
    echo "Error: refusing to release from a detached HEAD."
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "Error: gh is not authenticated. Run 'gh auth login' first."
    exit 1
fi

SIGNING_IDENTITY="Developer ID Application: Ryan Katayi (9TUBWSP9WT)"
TEAM_ID="9TUBWSP9WT"
APP_PATH="build/DerivedData/Build/Products/Release/Work.app"
DMG_NAME="Work.dmg"
ENTITLEMENTS_PATH="/tmp/Work-dist.entitlements"

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

echo "  Running the complete XCTest release gate..."
xcodebuild \
    -project Work.xcodeproj \
    -scheme Work \
    -configuration Debug \
    -destination 'platform=macOS' \
    test
echo "✓ XCTest release gate passed."
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
    -jobs 1 \
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
done || true
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

# 2. Attach it. We always mount under /tmp now — past attempts to mount at
#    /Volumes/Work hit "Operation not permitted" when ditto tried to copy
#    a signed .app bundle (xattr writes get blocked even when a touch/
#    small-file probe passes). The /tmp mount is rock-solid; the cost is
#    we skip the Finder window styling. Sparkle doesn't care about the
#    layout — it auto-installs from the bundle inside the DMG regardless.
FANCY_LAYOUT=0
MOUNT_POINT="/tmp/work-dmg-mount-${VERSION}"
mkdir -p "$MOUNT_POINT"
DEVICE=$(hdiutil attach "$RAW_DMG" \
    -mountpoint "$MOUNT_POINT" \
    -nobrowse -readwrite -noverify -noautoopen \
    | egrep '^/dev/' | sed 1q | awk '{print $1}')

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
# Versioned filename for the appcast enclosure — every release gets its own
# permanent, immutable URL (Work-2.7.0.dmg), never reused. This is the fix
# for Sparkle's "the update is improperly signed" error: with every release
# overwriting the SAME docs/Work.dmg, a CDN edge that hasn't yet propagated
# a deploy can serve an OLD version's bytes at a URL the appcast now
# advertises a NEW version's signature for — a real, observed failure mode,
# not hypothetical. A versioned URL can never collide across releases: once
# published its bytes never change again, so eventual CDN consistency can
# never produce a mismatch. docs/Work.dmg (unversioned) is kept ONLY as a
# "latest" alias for the marketing site's direct-download buttons — Sparkle
# never reads that URL, so its caching behavior is irrelevant to updates.
VERSIONED_DMG_NAME="Work-${VERSION}.dmg"
# The CNAME work.munyamakosa.com → munyamakosa.github.io/work is the URL
# baked into shipped binaries via SUFeedURL. Appcast enclosure URLs must
# match that host so Sparkle's signature verification and download path
# stay consistent across releases.
DOWNLOAD_URL="https://work.munyamakosa.com/$VERSIONED_DMG_NAME"
# Pull the build number from project.yml so sparkle:version matches what
# Sparkle compares against in the installed app's Info.plist. Without
# this, sparkle:version was the marketing string ("2.0.0") and Sparkle's
# numeric compare against the running build (24) misbehaved.
# NB: BSD sed (macOS) doesn't support \+ — extract the digits with grep -oE,
# which is portable. The old sed left BUILD_NUMBER as the whole YAML line, so
# sparkle:version came out as '  CURRENT_PROJECT_VERSION: "30"'.
BUILD_NUMBER=$(grep -E "^  CURRENT_PROJECT_VERSION:" project.yml | head -1 | grep -oE '[0-9]+' | head -1)
if [ -z "$BUILD_NUMBER" ]; then BUILD_NUMBER="$VERSION"; fi

# Attempt EdDSA signature
EDDSA_SIG=""
SIGN_UPDATE_BIN=""

# Check common locations for sign_update
for candidate in \
    "$SCRIPT_DIR/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
    "$HOME/Library/Developer/Xcode/DerivedData/Work-"*"/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
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
    echo "  ✗ sign_update not found; refusing to publish an unsigned Sparkle update."
    exit 1
fi

if ! echo "$EDDSA_SIG" | grep -Eq '^[A-Za-z0-9+/]{80,}={0,2}$'; then
    echo "  ✗ Sparkle signature is missing or malformed; refusing to publish."
    exit 1
fi

echo ""
echo "  ── Appcast XML snippet ──"
echo ""

EDDSA_ATTR="sparkle:edSignature=\"$EDDSA_SIG\""

APPCAST_SNIPPET=$(cat <<XMLEOF
<item>
    <title>Version ${VERSION}</title>
    <pubDate>${PUBLISH_DATE}</pubDate>
    <sparkle:version>${BUILD_NUMBER}</sparkle:version>
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
# release flow has the full body to hand to `gh release create`. Preflight
# refuses to start without it, so every draft release has complete notes.
# ─────────────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────"
echo "  Step 11: Creating GitHub release"
echo "──────────────────────────────────────────────────────────────"

TAG="v${VERSION}"
GH_TITLE="Work ${VERSION}"
TARGET_COMMIT=$(git rev-parse HEAD)

if gh release view "$TAG" &>/dev/null; then
    IS_DRAFT=$(gh release view "$TAG" --json isDraft --jq .isDraft)
    if [ "$IS_DRAFT" != "true" ]; then
        echo "Error: $TAG is already public; refusing to replace its binary."
        exit 1
    fi
    echo "  Existing draft $TAG found — replacing its DMG asset."
    gh release edit "$TAG" --target "$TARGET_COMMIT"
    gh release upload "$TAG" "$DMG_NAME" --clobber
    echo "✓ Re-uploaded $DMG_NAME to draft $TAG."
else
    gh release create "$TAG" \
        --draft \
        --target "$TARGET_COMMIT" \
        --title "$GH_TITLE" \
        --notes-file "$NOTES_FILE" \
        "$DMG_NAME"
    echo "✓ Draft GitHub release $TAG created with $DMG_NAME attached."
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 12: Stage the DMG into docs/ for the Vercel site
# work.munyamakosa.com (and atelier.munyamakosa.com) serve the DMG from the
# docs/ Vercel project, NOT from the GitHub release. The appcast's enclosure
# length + edSignature are computed against THIS exact build, so the staged
# copy MUST be the same bytes. Two copies go out: the VERSIONED one is what
# the appcast points to — permanent, never overwritten again, so a stale CDN
# edge can never serve mismatched bytes for it (see the note above
# VERSIONED_DMG_NAME). The unversioned Work.dmg is refreshed every release
# purely as a "latest" alias for the marketing site's download buttons;
# Sparkle never reads it, so its own caching lag doesn't matter.
# ─────────────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────"
echo "  Step 12: Staging DMG into docs/"
echo "──────────────────────────────────────────────────────────────"
DOCS_DIR="$SCRIPT_DIR/docs"
if [ -d "$DOCS_DIR" ]; then
    SRC_SIZE=$(stat -f%z "$DMG_NAME")

    cp "$DMG_NAME" "$DOCS_DIR/$VERSIONED_DMG_NAME"
    VERSIONED_COPIED_SIZE=$(stat -f%z "$DOCS_DIR/$VERSIONED_DMG_NAME")
    if [ "$VERSIONED_COPIED_SIZE" = "$SRC_SIZE" ]; then
        echo "✓ Copied $DMG_NAME → docs/$VERSIONED_DMG_NAME ($VERSIONED_COPIED_SIZE bytes — matches appcast enclosure length)."
    else
        echo "Error: docs/$VERSIONED_DMG_NAME size ($VERSIONED_COPIED_SIZE) != source ($SRC_SIZE)."
        exit 1
    fi

    cp "$DMG_NAME" "$DOCS_DIR/$DMG_NAME"
    LATEST_COPIED_SIZE=$(stat -f%z "$DOCS_DIR/$DMG_NAME")
    if [ "$LATEST_COPIED_SIZE" = "$SRC_SIZE" ]; then
        echo "✓ Copied $DMG_NAME → docs/$DMG_NAME (\"latest\" alias for the marketing site's download links)."
    else
        echo "Error: docs/$DMG_NAME size ($LATEST_COPIED_SIZE) != source ($SRC_SIZE)."
        exit 1
    fi
    echo "  Deploy it with:  (cd docs && vercel --prod --yes)"
else
    echo "Error: docs/ disappeared during the release."
    exit 1
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 13: Remove the built .app copy
# The Release Work.app left in build/ carries the PRODUCTION bundle id, so
# LaunchServices/Spotlight register a second "Atelier" at this path. Launching
# that copy (or Spotlight resolving to it) while /Applications runs → two live
# instances, one of them stale. The DMG is the artifact; the loose .app must go.
# ─────────────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────────────"
echo "  Step 13: Removing the loose Release .app (DMG is the artifact)"
echo "──────────────────────────────────────────────────────────────"
rm -rf "$APP_PATH"
echo "✓ Removed $APP_PATH — no duplicate com.munyamakosa.work registered."
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
echo "============================================================"
echo "  Release candidate v${VERSION} baked successfully"
echo "============================================================"
echo ""
echo "Artifacts:"
echo "  • $DMG_NAME ($(du -h "$DMG_NAME" | cut -f1) — notarized & stapled)"
echo ""
echo "Next steps:"
echo "  1. Add the appcast XML snippet above to docs/appcast.xml"
echo "     (it points to the VERSIONED URL — $VERSIONED_DMG_NAME — never edit"
echo "     an old entry's url/length/signature to match a later build)"
echo "  2. Add a v${VERSION} <article> to docs/releases.html (top of the list)"
echo "  3. Deploy the site:  (cd docs && vercel --prod --yes)"
echo "     (docs/$VERSIONED_DMG_NAME and docs/$DMG_NAME were both already staged in Step 12)"
echo "  4. git commit + push appcast.xml, releases.html, and the staged DMGs"
echo "  5. Verify live size matches the appcast (check the VERSIONED url — this"
echo "     is the one Sparkle actually downloads):"
echo "     curl -sI https://work.munyamakosa.com/$VERSIONED_DMG_NAME | grep -i content-length"
echo "  6. Publish the draft GitHub release only after the live URL and appcast verify"
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
