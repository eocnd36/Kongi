#!/usr/bin/env bash
# Kongi.app 번들과 배포용 zip을 만듭니다.
#
#   ./scripts/build-app.sh                 # 현재 Mac 아키텍처용
#   UNIVERSAL=1 ./scripts/build-app.sh     # Apple Silicon + Intel 유니버설
#
# 환경 변수
#   VERSION            앱 버전 (기본: git 태그 → 0.0.0-dev)
#   BUNDLE_ID          번들 ID (기본: io.github.claudeusagebar)
#   REPO_URL           설정 화면의 GitHub 링크 (CI에서는 자동 설정)
#   CODESIGN_IDENTITY  서명 인증서 이름 (기본: "-" = ad-hoc 서명)
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Kongi"
# SwiftPM 제품 이름(내부)과 앱 번들 안 실행 파일 이름
PRODUCT="ClaudeUsageBar"
EXECUTABLE="Kongi"
HOOK_HELPER="claude-usage-hook"
BUNDLE_ID="${BUNDLE_ID:-io.github.claudeusagebar}"
REPO_URL="${REPO_URL:-}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
  VERSION="${VERSION:-0.0.0-dev}"
fi
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCHS=(arm64 x86_64)
else
  ARCHS=("$(uname -m)")
fi

DIST="dist"
APP="$DIST/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 1) 아키텍처별로 빌드한 뒤 lipo로 합칩니다 (Xcode 없이 Command Line Tools만으로도 동작).
BINARIES=()
HELPERS=()
for arch in "${ARCHS[@]}"; do
  echo "▸ Building $arch"
  swift build -c release --arch "$arch" --product "$PRODUCT"
  swift build -c release --arch "$arch" --product "$HOOK_HELPER"
  BIN_PATH="$(swift build -c release --arch "$arch" --show-bin-path)"
  BINARIES+=("$BIN_PATH/$PRODUCT")
  HELPERS+=("$BIN_PATH/$HOOK_HELPER")
done
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/$EXECUTABLE"
# Claude Code 훅 도우미 (앱이 연동 설치 때 ~/Library/Application Support로 복사)
lipo -create "${HELPERS[@]}" -output "$APP/Contents/MacOS/$HOOK_HELPER"

# 2) 리소스 (현지화 문자열, 아이콘)
cp -R Resources/*.lproj "$APP/Contents/Resources/"
# 가져온 오픈 소스 코드의 라이선스
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# 3) Info.plist (지원 언어 목록은 Resources/*.lproj에서 만듭니다)
LOCALIZATIONS=""
for dir in Resources/*.lproj; do
  LOCALIZATIONS+="<string>$(basename "$dir" .lproj)</string>"
done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                 <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>          <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>           <string>$EXECUTABLE</string>
  <key>CFBundleIdentifier</key>           <string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key>          <string>APPL</string>
  <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
  <key>CFBundleVersion</key>              <string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key>             <string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key>    <string>en</string>
  <key>CFBundleLocalizations</key>        <array>$LOCALIZATIONS</array>
  <key>LSMinimumSystemVersion</key>       <string>13.0</string>
  <key>LSUIElement</key>                  <true/>
  <key>LSApplicationCategoryType</key>    <string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key>     <string>MIT License</string>
  <key>ClaudeUsageBarRepositoryURL</key>  <string>$REPO_URL</string>
  <key>NSAppleEventsUsageDescription</key> <string>Kongi opens the terminal window where a Claude Code session is running.</string>
  <key>NSCalendarsFullAccessUsageDescription</key> <string>Kongi shows your next meeting in the island with a button to join it. Only if you turn this on.</string>
  <key>NSCalendarsUsageDescription</key> <string>Kongi shows your next meeting in the island with a button to join it. Only if you turn this on.</string>
  <key>NSLocalNetworkUsageDescription</key> <string>Kongi talks to the Kongi app on your Android phone over your Wi-Fi. Only if you turn this on.</string>
  <key>NSBonjourServices</key> <array><string>_kongi._tcp</string></array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# 4) 서명 (기본은 ad-hoc. Developer ID가 있으면 CODESIGN_IDENTITY로 지정)
SIGN_ARGS=(--force --sign "$CODESIGN_IDENTITY")
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
# 안쪽 실행 파일(훅 도우미)부터 서명한 뒤 앱 전체를 서명합니다.
codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/$HOOK_HELPER"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict "$APP"

# 5) 배포용 zip
ZIP="$DIST/Kongi-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo
echo "✓ $APP  ($(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE"))"
echo "✓ $ZIP"
