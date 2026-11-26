#!/bin/zsh
# Compila JBL EON Control (arm64 + x86_64 universal), firma ad-hoc.
set -e
cd "$(dirname "$0")"
APP="JBL EON Control.app"; rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" build
for a in arm64 x86_64; do swiftc -O -parse-as-library -target $a-apple-macos13.0 Sources/main.swift -o build/EONControl-$a; done
lipo -create build/EONControl-arm64 build/EONControl-x86_64 -output "$APP/Contents/MacOS/EONControl"
mkdir -p "$APP/Contents/Resources"; cp AppIcon.icns "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
ID=$(security find-identity -v -p codesigning | awk -F\" '/Apple Development/{print $2; exit}'); codesign --force --deep -s "${ID:--}" "$APP"
echo "OK -> $PWD/$APP"; lipo -info "$APP/Contents/MacOS/EONControl"

# --- Paquetes para distribuir ---
mkdir -p dist; find dist -name '*.zip' -delete; rm -rf build/intel
ditto -c -k --keepParent "$APP" "dist/JBL EON Control (universal).zip"
mkdir -p build/intel; cp -R "$APP" "build/intel/$APP"
lipo -thin x86_64 "build/intel/$APP/Contents/MacOS/EONControl" -output "build/intel/$APP/Contents/MacOS/EONControl.thin"
mv "build/intel/$APP/Contents/MacOS/EONControl.thin" "build/intel/$APP/Contents/MacOS/EONControl"
codesign --force --deep -s "${ID:--}" "build/intel/$APP"
ditto -c -k --keepParent "build/intel/$APP" "dist/JBL EON Control (Intel).zip"
ls -la dist
