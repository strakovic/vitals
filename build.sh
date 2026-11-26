#!/bin/zsh
# Builds Vitals.app into ./build.
#   ./build.sh            build only
#   ./build.sh install    copy to /Applications and start it at login (LaunchAgent)
#   ./build.sh release    build/Vitals.zip for GitHub Releases. Signed with a "Developer ID Application"
#                         certificate and notarized when one is in the keychain and an App Store Connect
#                         API key is set (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH); ad-hoc signed otherwise.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Vitals"

APP="build/Vitals.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Vitals"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" | sed -E 's/.*"(.+)"/\1/' || true)"
if [[ "${1:-}" == "release" ]]; then
  IDENTITY="${DEVELOPER_ID:--}"   # Developer ID, or ad-hoc: never a personal development certificate
else
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.+)"/\1/' || true)"
fi
TIMESTAMP=()
[[ "$IDENTITY" == Developer\ ID* ]] && TIMESTAMP=(--timestamp)
codesign --force --options runtime "${TIMESTAMP[@]}" --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  LABEL="app.diferent.Vitals"
  DOMAIN="gui/$(id -u)"
  AGENT=~/Library/LaunchAgents/$LABEL.plist
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  pkill -x Vitals 2>/dev/null || true
  while pgrep -x Vitals >/dev/null; do sleep 0.2; done
  mkdir -p ~/Library/LaunchAgents
  rm -rf ~/Applications/Vitals.app   # older installs lived here
  rm -rf /Applications/Vitals.app
  cp -R "$APP" /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Vitals.app
  sed "s|__APP__|/Applications/Vitals.app|" Resources/LaunchAgent.plist > "$AGENT"
  launchctl bootstrap "$DOMAIN" "$AGENT"
  echo "Installed to /Applications/Vitals.app, started at login by $AGENT"
fi

if [[ "${1:-}" == "release" ]]; then
  rm -f build/Vitals.zip
  ditto -c -k --keepParent "$APP" build/Vitals.zip
  if [[ "$IDENTITY" == Developer\ ID* && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -f "${ASC_KEY_PATH:-}" ]]; then
    echo "Notarizing (a few minutes)..."
    xcrun notarytool submit build/Vitals.zip --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
    xcrun stapler staple "$APP"
    rm -f build/Vitals.zip
    ditto -c -k --keepParent "$APP" build/Vitals.zip
    spctl -a -vv "$APP"
  else
    echo "Not notarized: needs a Developer ID Application certificate and ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH."
  fi
  echo "Release zip: build/Vitals.zip ($(du -h build/Vitals.zip | cut -f1))"

  # The download people open: a disk image with Vitals next to an Applications shortcut.
  STAGE="build/dmg"
  rm -rf "$STAGE" build/Vitals.dmg
  mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/Vitals.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "Vitals" -srcfolder "$STAGE" -fs HFS+ -format ULFO build/Vitals.dmg
  rm -rf "$STAGE"
  if [[ "$IDENTITY" == Developer\ ID* ]]; then
    codesign --force --timestamp --sign "$IDENTITY" build/Vitals.dmg
    if [[ -n "${ASC_KEY_ID:-}" && -f "${ASC_KEY_PATH:-}" ]]; then
      xcrun notarytool submit build/Vitals.dmg --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
      xcrun stapler staple build/Vitals.dmg
    fi
  fi
  echo "Release disk image: build/Vitals.dmg ($(du -h build/Vitals.dmg | cut -f1))"
fi
