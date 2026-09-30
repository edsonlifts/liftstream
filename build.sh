#!/bin/zsh
# Compila o Liftstream e instala a cópia da Mesa (~/Desktop/Liftstream.app).
set -euo pipefail
cd "${0:A:h}"

APP="build/Liftstream.app"

if [[ ! -x uxplay-src/build/uxplay ]]; then
  # A versão do UxPlay fica fixada em UXPLAY_COMMIT: é o código-fonte que o AVISOS-DE-TERCEIROS aponta.
  if [[ ! -d uxplay-src ]]; then
    mkdir uxplay-src
    (cd uxplay-src && git init -q && git fetch -q --depth 1 https://github.com/FDH2/UxPlay.git "$(cat ../UXPLAY_COMMIT)" && git checkout -q FETCH_HEAD)
  fi
  (cd uxplay-src && mkdir -p build && cd build && cmake .. -DCMAKE_BUILD_TYPE=Release && make -j8)
fi

mkdir -p build
[[ build/AppIcon.icns -nt icone.swift && build/AppIcon.icns -nt recursos/marca.png ]] || swift icone.swift build/AppIcon.icns

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 Liftstream.swift -o "$APP/Contents/MacOS/Liftstream"
cp Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp recursos/logo-horizontal.png "$APP/Contents/Resources/logo-horizontal.png"
# Fica em Helpers, não em MacOS: ali ele não herda o Info.plist do app nem vira um segundo ícone no Dock.
cp uxplay-src/build/uxplay "$APP/Contents/Helpers/uxplay"

codesign -s - --force "$APP/Contents/Helpers/uxplay"
codesign -s - --force "$APP"

rm -rf "$HOME/Desktop/Espelho PIP.app" "$HOME/Desktop/Liftstream.app"
cp -R "$APP" "$HOME/Desktop/"
echo "Pronto: ~/Desktop/Liftstream.app"
