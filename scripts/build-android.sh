#!/usr/bin/env bash
# 안드로이드 앱 APK를 만듭니다: dist/Kongi-<버전>.apk
#
# Android SDK와 Gradle은 저장소 안의 .tools/에 받아 둡니다 (git에는 들어가지 않음).
# 서명 키를 KONGI_KEYSTORE, KONGI_KEYSTORE_PASSWORD, KONGI_KEY_ALIAS, KONGI_KEY_PASSWORD로 넘기면 그 키로,
# 없으면 debug 키로 서명합니다.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION="${VERSION:-2.2.1}"
TOOLS="$ROOT/.tools"
SDK="$TOOLS/android-sdk"
CMDLINE="$SDK/cmdline-tools/latest"

mkdir -p "$TOOLS"
if [[ ! -d "$CMDLINE" ]]; then
  echo "▸ Downloading Android command-line tools"
  curl -fsSLo "$TOOLS/cmdline.zip" https://dl.google.com/android/repository/commandlinetools-mac-13114758_latest.zip
  rm -rf "$TOOLS/sdk-tmp" && unzip -q "$TOOLS/cmdline.zip" -d "$TOOLS/sdk-tmp"
  mkdir -p "$SDK/cmdline-tools" && mv "$TOOLS/sdk-tmp/cmdline-tools" "$CMDLINE"
  rm -rf "$TOOLS/sdk-tmp" "$TOOLS/cmdline.zip"
fi
if [[ ! -d "$SDK/platforms/android-35" ]]; then
  echo "▸ Installing the Android SDK platform"
  # sdkmanager 스크립트는 공백이 있는 경로에서 깨지므로 java로 바로 실행합니다.
  yes | ANDROID_USER_HOME="$TOOLS/android-home" java "-Dcom.android.sdklib.toolsdir=$CMDLINE" \
    -classpath "$CMDLINE/lib/sdkmanager-classpath.jar" com.android.sdklib.tool.sdkmanager.SdkManagerCli \
    --sdk_root="$SDK" "platforms;android-35" "build-tools;35.0.0" "platform-tools" >/dev/null
fi
printf 'sdk.dir=%s\n' "$SDK" > android/local.properties

# 항상 줄이고 최적화한 release로 만듭니다 (Compose는 debug에서 눈에 띄게 느림).
OUT=android/app/build/outputs/apk/release/app-release.apk

echo "▸ Building the release APK"
(cd android && GRADLE_USER_HOME="$TOOLS/gradle-home" ./gradlew -q ":app:testDebugUnitTest" ":app:assembleRelease" -PkongiVersion="$VERSION")
mkdir -p dist
cp "$OUT" "dist/Kongi-$VERSION.apk"
echo "✓ dist/Kongi-$VERSION.apk"
