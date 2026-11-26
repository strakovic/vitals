#!/bin/zsh
# Builds Vitals.app into ./build.
#   ./build.sh            build only
#   ./build.sh install    copy to /Applications and start it at login (LaunchAgent)
#   ./build.sh release    ad-hoc signed build zipped to build/Vitals.zip for GitHub Releases
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
if [[ "${1:-}" == "release" ]]; then
  IDENTITY="-"   # ad-hoc: no personal certificate inside public downloads
else
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.+)"/\1/' || true)"
fi
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"
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
  echo "Release zip: build/Vitals.zip ($(du -h build/Vitals.zip | cut -f1))"
fi
