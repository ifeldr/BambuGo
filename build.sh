#!/bin/bash
# Compila BambuGo.app (universale arm64 + x86_64). Richiede gli Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc non trovato. Installa i Command Line Tools con:  xcode-select --install"
    exit 1
fi

APP="build/BambuGo.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BINARIES=()
for ARCH in arm64 x86_64; do
    echo "→ Compilo per $ARCH…"
    swiftc -O -parse-as-library \
        -target "$ARCH-apple-macos13.0" \
        Sources/*.swift \
        -o "build/BambuGo-$ARCH"
    BINARIES+=("build/BambuGo-$ARCH")
done

lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/BambuGo"
rm -f "${BINARIES[@]}"
cp Info.plist "$APP/Contents/Info.plist"

# Firma ad-hoc (necessaria per notifiche e avvio al login)
codesign --force --sign - "$APP"

echo
echo "✅ Fatto: $APP"
echo "   Per installarla:  cp -R \"$APP\" /Applications/ && open /Applications/BambuGo.app"
