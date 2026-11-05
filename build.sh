#!/bin/bash
# Сборка AILimits без Xcode: swiftc + ручная сборка бандла + ad-hoc подпись.
#   ./build.sh            — собрать build/AILimits.app (universal: arm64 + x86_64)
#   ./build.sh install    — собрать, установить в ~/Applications и запустить
#   ./build.sh dmg        — собрать и упаковать в build/AILimits-<версия>.dmg
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/App-Info.plist)
FLAGS=(-swift-version 5 -O -parse-as-library)
ARCHS=(arm64 x86_64)

APP="build/AILimits.app"
APPEX="$APP/Contents/PlugIns/AILimitsWidget.appex"
OBJ="build/obj"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APPEX/Contents/MacOS" "$OBJ"

# compile <выходной бинарник> <доп. флаги и исходники...>
compile() {
  local out="$1"; shift
  local slices=()
  for arch in "${ARCHS[@]}"; do
    local slice="$OBJ/$(basename "$out")-$arch"
    swiftc "${FLAGS[@]}" -target "$arch-apple-macos14.0" "$@" -o "$slice"
    slices+=("$slice")
  done
  lipo -create "${slices[@]}" -output "$out"
}

echo "→ Компиляция приложения (${ARCHS[*]})"
compile "$APP/Contents/MacOS/AILimits" Sources/Shared/*.swift Sources/App/*.swift
cp Resources/App-Info.plist "$APP/Contents/Info.plist"

echo "→ Компиляция виджета (${ARCHS[*]})"
compile "$APPEX/Contents/MacOS/AILimitsWidget" -application-extension Sources/Shared/*.swift Sources/Widget/*.swift
cp Resources/Widget-Info.plist "$APPEX/Contents/Info.plist"

echo "→ Ресурсы: локализации и иконки"
mkdir -p "$APP/Contents/Resources" "$APPEX/Contents/Resources"
for bundle in "$APP" "$APPEX"; do
  cp -R Resources/en.lproj Resources/ru.lproj "$bundle/Contents/Resources/"
done
swift tools/make_appicon.swift "$APP/Contents/Resources/AppIcon.icns"
swift tools/make_icons.swift "$APP/Contents/Resources"
cp "$APP/Contents/Resources/"*.png "$APPEX/Contents/Resources/" 2>/dev/null || true

echo "→ Подпись (ad-hoc)"
codesign --force --sign - --entitlements Resources/Widget.entitlements "$APPEX"
codesign --force --sign - "$APP"

case "${1:-}" in
  install)
    DEST="$HOME/Applications/AILimits.app"
    echo "→ Установка в $DEST"
    pkill -x AILimits 2>/dev/null || true
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    pluginkit -a "$DEST/Contents/PlugIns/AILimitsWidget.appex" || true
    open "$DEST"
    ;;
  dmg)
    DMG="build/AILimits-$VERSION.dmg"
    STAGE="build/dmg"
    echo "→ Упаковка $DMG"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "AI Limits $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "✓ DMG: $DMG ($(du -h "$DMG" | cut -f1))"
    ;;
esac
echo "✓ Готово: $APP"
