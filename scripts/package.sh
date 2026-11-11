#!/usr/bin/env bash
#
# 打包 HGhub:
#   ./scripts/package.sh mac   → dist/HGhub-<版本>.dmg(macOS,拖进「应用程序」即可)
#   ./scripts/package.sh ios   → dist/HGhub-<版本>-unsigned.ipa(iOS,需自行签名安装)
#   ./scripts/package.sh       → 两个都打
#
# macOS 用 ad-hoc 签名(无需开发者账号);iOS 完全不签名,交给 AltStore / Sideloadly / Xcode 签。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=src
PROJ=$SRC/HGhub.xcodeproj
SCHEME=HGhub
DD=build/package
DIST=dist
VER=$(grep -m1 'MARKETING_VERSION' "$SRC/project.yml" | sed 's/.*: *"//; s/"//')
APP_NAME=HGhub

mkdir -p "$DIST"

mac() {
  echo "==> 构建 macOS Release"
  xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$DD/mac" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build >/dev/null

  local app="$DD/mac/Build/Products/Release/$APP_NAME.app"
  local stage="$DD/stage-mac"
  rm -rf "$stage"
  mkdir -p "$stage"
  cp -R "$app" "$stage/"
  codesign --force --deep --sign - "$stage/$APP_NAME.app"
  ln -s /Applications "$stage/Applications"

  local dmg="$DIST/$APP_NAME-$VER.dmg"
  rm -f "$dmg"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$stage" -ov -format UDZO "$dmg"
  rm -rf "$stage"
  echo "==> $dmg"
}

ios() {
  echo "==> 构建 iOS Release(不签名)"
  xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$DD/ios" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build >/dev/null

  local app="$DD/ios/Build/Products/Release-iphoneos/$APP_NAME.app"
  local stage="$DD/stage-ios"
  rm -rf "$stage"
  mkdir -p "$stage/Payload"
  cp -R "$app" "$stage/Payload/"
  local ipa="$DIST/$APP_NAME-$VER-unsigned.ipa"
  rm -f "$ipa"
  (cd "$stage" && zip -qry "$OLDPWD/$ipa" Payload)
  rm -rf "$stage"
  echo "==> $ipa"
}

case "${1:-all}" in
  mac) mac ;;
  ios) ios ;;
  all) mac; ios ;;
  *) echo "用法: $0 [mac|ios|all]"; exit 2 ;;
esac
