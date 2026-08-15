#!/bin/bash
# ビルド済みバイナリを .app バンドルへ包んで ad-hoc 署名する。
#
#   scripts/make-app.sh [debug|release]   → .build/strata.app
#
# なぜ必要か:
#   `metaphor new` が作るのは素の SwiftPM 実行ファイルで .app ではない。
#   macOS の TCC は「Info.plist に用途文言を持つ、署名済みバンドル」にしか
#   カメラ/マイクの許可ダイアログを出さないため、`swift run` のままだと
#   AVCaptureDevice.authorizationStatus は notDetermined から動かず、
#   フレームが 1 枚も来ないまま無言で失敗する（metaphor / metaphor-cli に
#   このバンドル化経路が無いのが穴。README の「踏んだ穴」を参照）。
#
# 常設運用でも .app は必要（Dock/LaunchServices から起動する、
# ログイン項目に登録する、クラッシュ後に自動復帰させる、いずれも .app 前提）。
set -euo pipefail

cd "$(dirname "$0")/.."

config="${1:-release}"
binary_name="Sketch0815Strata"
bundle_id="dev.shinyaoguri.metaphor-sketches.strata"
app=".build/strata.app"

echo "==> swift build -c $config"
swift build -c "$config"

bin_dir="$(swift build -c "$config" --show-bin-path)"
if [ ! -x "$bin_dir/$binary_name" ]; then
  echo "binary not found: $bin_dir/$binary_name" >&2
  exit 1
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$bin_dir/$binary_name" "$app/Contents/MacOS/"
# SwiftPM のリソースバンドルは実行ファイルと同じ階層に置く必要がある
for b in "$bin_dir"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$app/Contents/MacOS/"
done

# Syphon.framework（metaphor の binaryTarget）は swift run では .build 直下から
# 解決されるが、.app へ持ち出すと付いてこない。@rpath は実行ファイル位置を
# 見るので隣へ置く（これも「.app 化の経路が用意されていない」の一部）。
for f in "$bin_dir"/*.framework; do
  [ -e "$f" ] && cp -R "$f" "$app/Contents/MacOS/"
done

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>strata</string>
  <key>CFBundleDisplayName</key><string>0815-strata</string>
  <key>CFBundleExecutable</key><string>$binary_name</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSCameraUsageDescription</key>
  <string>地形の隆起と色温度を、目の前の動きから決めるために使います。映像は保存も送信もしません。</string>
  <key>NSCameraUseContinuityCameraDeviceType</key><true/>
</dict>
</plist>
PLIST

# TCC は安定した署名 ID を要求する。ad-hoc 署名でもローカルでは通る。
codesign --force --sign - --identifier "$bundle_id" "$app" >/dev/null 2>&1 \
  || echo "warning: codesign failed (TCC may not prompt)" >&2

echo "built: $app"
echo "run:   open -a \"\$PWD/$app\"   (環境変数を渡すなら --env)"
