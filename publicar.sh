#!/bin/zsh
# Publica uma versão: compila, prova sem Homebrew, empacota, envia o código e cria o release no GitHub.
# Antes, suba CFBundleShortVersionString no Info.plist. Uso: ./publicar.sh "o que mudou"
set -euo pipefail
cd "${0:A:h}"
export PATH="/opt/homebrew/bin:$PATH"

notas="${1:?Diga o que mudou: ./publicar.sh \"notas da versão\"}"
versao=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
tag="v$versao"

if gh release view "$tag" >/dev/null 2>&1; then
  echo "O release $tag já existe. Suba a versão no Info.plist."
  exit 1
fi

./build.sh
./empacotar.sh teste
./provar.sh
./empacotar.sh

git add -A
git diff --cached --quiet || git commit -q -m "Liftstream $versao"
git push -q origin main
gh release create "$tag" dist/Liftstream.zip --target main --title "Liftstream $versao" --notes "$notas"
echo "Publicado: $(gh release view "$tag" --json url --jq .url)"
