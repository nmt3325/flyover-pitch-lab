#!/usr/bin/env bash
set -euo pipefail

# Builds an unsigned device app, packaged as Payload/*.app in an .ipa.
# No provisioning profiles, Apple ID, signing key, or Maps entitlement.
cd "$(dirname "$0")/.."

xcodegen generate --spec project.yml
xcodebuild \
  -project FlyoverPitchLabIOS.xcodeproj \
  -scheme FlyoverPitchLab \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$PWD/.build-ios" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  clean build

APP="$PWD/.build-ios/Build/Products/Release-iphoneos/FlyoverPitchLab.app"
test -f "$APP/Info.plist"
test -f "$APP/FlyoverPitchLab"

mkdir -p dist
rm -rf dist/ios-staging
mkdir -p dist/ios-staging/Payload
cp -R "$APP" dist/ios-staging/Payload/FlyoverPitchLab.app
rm -rf dist/ios-staging/Payload/FlyoverPitchLab.app/_CodeSignature
rm -f dist/ios-staging/Payload/FlyoverPitchLab.app/embedded.mobileprovision

IPA="$PWD/dist/FlyoverPitchLab-iOS-iPadOS-unsigned.ipa"
rm -f "$IPA"
(cd dist/ios-staging && zip -qry "$IPA" Payload)
unzip -t "$IPA" | tail -n 2
ls -lh "$IPA"
