#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="0.4.0"
SCRATCH="${SCRATCH:-.build}"
FH="$PWD/.signing/fakehome"

# A debug build holds the test modes, which post events with the app's Accessibility permission.
# Its own bundle id stops it inheriting a grant made to the real app, and it is never packaged.
CONFIG="${CONFIG:-release}"
if [ "$CONFIG" = release ]; then
	NAME="Mousey"
	ID="io.github.imsumitkumar.mousey"
	APP="dist/Mousey.app"
else
	NAME="Mousey Debug"
	ID="io.github.imsumitkumar.mousey.debug"
	APP="dist/debug/Mousey Debug.app"
fi

HASH=$(scripts/make-signing-identity.sh)
HOME="$FH" security unlock-keychain -p "$(cat .signing/password)" "$PWD/.signing/signing.keychain-db"

swift build -c "$CONFIG" --arch arm64 --arch x86_64 --scratch-path "$SCRATCH"
BINDIR="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --scratch-path "$SCRATCH" --show-bin-path)"
BIN="$BINDIR/Mousey"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/Mousey"
cp "$BINDIR/MouseyHelper" "$APP/Contents/MacOS/MouseyHelper"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>$ID</string>
	<key>CFBundleName</key><string>$NAME</string>
	<key>CFBundleExecutable</key><string>Mousey</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>12.0</string>
	<key>LSUIElement</key><true/>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>NSLocalNetworkUsageDescription</key><string>Mousey finds your other Mac on this network and sends it your keyboard and pointer input, encrypted.</string>
	<key>NSBonjourServices</key>
	<array>
		<string>_mousey._udp</string>
		<string>_mousey-pair._tcp</string>
		<string>_mousey-clip._tcp</string>
	</array>
	<key>NSHumanReadableCopyright</key><string>Your input goes only to the Mac you pair with.</string>
</dict>
</plist>
PLIST

# Debug info holds the build folder's path, which would publish the builder's account name.
if [ "$CONFIG" = release ]; then
	strip -S -x "$APP/Contents/MacOS/Mousey" "$APP/Contents/MacOS/MouseyHelper"
fi

# The hardened runtime stops another program loading its code into the app, where it would hold the app's permissions.
HOME="$FH" codesign -f -s "$HASH" --options runtime -i io.github.imsumitkumar.mousey.awdl-helper "$APP/Contents/MacOS/MouseyHelper"
HOME="$FH" codesign -f -s "$HASH" --options runtime -i "$ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "archs: $(lipo -archs "$APP/Contents/MacOS/Mousey")"
echo "$(codesign -dvvv "$APP" 2>&1 | grep '^CDHash=')"
echo "designated requirement:"
codesign -d -r- "$APP" 2>&1 | grep designated | sed -E 's/H"[0-9a-f]+"/H"<masked>"/'

if [ "$CONFIG" != release ]; then
	echo "Any program running as you can use this build if you grant it Accessibility. After testing, run: tccutil reset Accessibility $ID"
	exit 0
fi

if LC_ALL=C grep -rqaF -e '/Users/' -e "$PWD" "$APP"; then
	echo "the app holds a path from this Mac, so it was not packaged" >&2
	exit 1
fi

rm -f dist/Mousey.zip
ditto -c -k --keepParent "$APP" dist/Mousey.zip
ls -l dist/Mousey.zip

# A disk image for sharing: the app, a shortcut to Applications, and the first-open instructions.
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Mousey.app"
ln -s /Applications "$STAGE/Applications"
cp docs/INSTALL.md "$STAGE/Read Me First.txt"
rm -f dist/Mousey.dmg
hdiutil create -quiet -volname "Mousey" -srcfolder "$STAGE" -format UDZO -ov dist/Mousey.dmg
rm -rf "$STAGE"
ls -l dist/Mousey.dmg
