#!/bin/zsh
# Faz a cópia do Liftstream que roda em outro Mac (sem Homebrew): dist/Liftstream.zip.
# Usa o app que o build.sh deixou em build/; o da Mesa continua dependendo do Homebrew.
#   ./empacotar.sh           cópia para enviar
#   ./empacotar.sh teste     cópia em dist/teste com o gst-launch, para provar sem Homebrew (provar.sh)
set -euo pipefail
cd "${0:A:h}"
export PATH="/opt/homebrew/bin:$PATH"

[[ -d "build/Liftstream.app" ]] || { echo "Rode ./build.sh antes."; exit 1; }

DESTINO="dist/Liftstream"
[[ "${1:-}" == "teste" ]] && DESTINO="dist/teste"
rm -rf "$DESTINO"
mkdir -p "$DESTINO"
APP="$DESTINO/Liftstream.app"
ditto "build/Liftstream.app" "$APP"

extras=()
[[ "${1:-}" == "teste" ]] && extras=(--extra /opt/homebrew/bin/gst-launch-1.0 --extra /opt/homebrew/bin/gst-inspect-1.0 --plugin videotestsrc --plugin audiotestsrc)
python3 embutir.py "$APP" $extras

# As bibliotecas do Homebrew foram compiladas para o macOS 26; dizer isso é melhor que fechar sem explicação.
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 26.0" "$APP/Contents/Info.plist"

codesign -s - --force "$APP"
codesign --verify --strict "$APP"

[[ "${1:-}" == "teste" ]] && { echo "Pronto: $APP"; exit 0; }

cp LEIA-ME.txt LICENSE "$DESTINO/"
cp "$APP/Contents/Resources/AVISOS-DE-TERCEIROS.txt" "$DESTINO/"
rm -f "dist/Liftstream.zip"
ditto -c -k --keepParent "$DESTINO" "dist/Liftstream.zip"
echo "Pronto: dist/Liftstream.zip ($(du -h "dist/Liftstream.zip" | cut -f1))"
