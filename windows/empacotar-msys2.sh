#!/usr/bin/env bash
# Roda no MSYS2 (UCRT64). Monta a pasta do Liftstream para Windows: uxplay.exe, o GStreamer e só as DLLs
# de que eles dependem, mais o aviso de licenças.
#   empacotar-msys2.sh <pasta de destino> <uxplay.exe> [teste]
# "teste" junta também o gst-launch, o gst-inspect e plugins de fonte de teste, só para provar a cópia (provar.ps1).
set -euo pipefail

DESTINO="$1"
UXPLAY="$2"
MODO="${3:-}"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUG=/ucrt64/lib/gstreamer-1.0
LIBEXEC=/ucrt64/libexec/gstreamer-1.0

# Um plugin por elemento que o UxPlay e o app usam (a lista do Mac, trocando o áudio do macOS pelos do Windows).
# Decodificação de vídeo fica só no libav (software): é a que sempre funciona, sem depender da placa de vídeo.
PLUGINS=(app audioconvert audioparsers audioresample autodetect coreelements imagefreeze isomp4 jpeg level libav
         multipart pango playback tcp typefindfunctions videoconvertscale videofilter videoparsersbad volume)
SONS=(directsound wasapi wasapi2)   # o autoaudiosink escolhe entre os que existirem
EXECUTAVEIS=()
if [[ "$MODO" == teste ]]; then
  PLUGINS+=(videotestsrc audiotestsrc x264)
  EXECUTAVEIS=(/ucrt64/bin/gst-launch-1.0.exe /ucrt64/bin/gst-inspect-1.0.exe)
fi

rm -rf "$DESTINO"
mkdir -p "$DESTINO/plugins"

origens_plugins=()
for nome in "${PLUGINS[@]}"; do
  [[ -f "$PLUG/libgst$nome.dll" ]] || { echo "falta o plugin $nome em $PLUG"; exit 1; }
  origens_plugins+=("$PLUG/libgst$nome.dll")
done
achou_som=0
for nome in "${SONS[@]}"; do
  if [[ -f "$PLUG/libgst$nome.dll" ]]; then origens_plugins+=("$PLUG/libgst$nome.dll"); achou_som=1; echo "saída de áudio: $nome"; fi
done
[[ $achou_som -eq 1 ]] || { echo "nenhum plugin de saída de áudio do Windows (${SONS[*]})"; exit 1; }

# Fecho das dependências: tudo que /ucrt64 fornece e o uxplay, o scanner e os plugins pedem, direta ou indiretamente.
declare -A VISTO=()
pilha=("$UXPLAY" "$LIBEXEC/gst-plugin-scanner.exe" "${EXECUTAVEIS[@]}" "${origens_plugins[@]}")
while ((${#pilha[@]})); do
  f="${pilha[-1]}"
  unset 'pilha[-1]'
  [[ -n "${VISTO[$f]:-}" ]] && continue
  VISTO[$f]=1
  saida="$(ldd "$f" 2>&1 || true)"
  if grep -qi 'not found' <<<"$saida"; then
    echo "dependência não encontrada para $f:"; grep -i 'not found' <<<"$saida"; exit 1
  fi
  while read -r dep; do
    [[ -n "$dep" && -z "${VISTO[$dep]:-}" ]] && pilha+=("$dep")
  done < <(awk '/=>/ {print $3}' <<<"$saida" | grep -E '^/ucrt64/' || true)
done

cp "$UXPLAY" "$DESTINO/uxplay.exe"
cp "$LIBEXEC/gst-plugin-scanner.exe" "$DESTINO/"
for e in "${EXECUTAVEIS[@]}"; do cp "$e" "$DESTINO/"; done
for p in "${origens_plugins[@]}"; do cp "$p" "$DESTINO/plugins/"; done
bibliotecas=()
for f in "${!VISTO[@]}"; do
  [[ "$f" == /ucrt64/bin/*.dll ]] || continue
  cp "$f" "$DESTINO/"
  bibliotecas+=("$f")
done

# Licenças: cada arquivo vem de um pacote do MSYS2, que diz versão, licença e página do projeto.
COMMIT="${GITHUB_SHA:-desconhecido}"
UXPLAY_COMMIT="$(tr -d '\r\n' < "$RAIZ/UXPLAY_COMMIT")"
pacotes="$(pacman -Qoq "${bibliotecas[@]}" "${origens_plugins[@]}" "$LIBEXEC/gst-plugin-scanner.exe" 2>/dev/null | sort -u)"
{
  echo "AVISOS DE TERCEIROS · Liftstream para Windows"
  echo
  echo "O Liftstream é distribuído sob a GPL-3.0 (arquivo LICENSE; código em https://github.com/edsonlifts/liftstream, commit $COMMIT)."
  echo "Ele leva dentro de si os programas abaixo, cada um sob a própria licença. Em cada linha estão a versão"
  echo "embutida, a licença, a página do projeto e onde achar o código-fonte dessa versão."
  echo
  echo "UxPlay · GPL-3.0 · https://github.com/FDH2/UxPlay · commit $UXPLAY_COMMIT"
  echo "    código-fonte: https://github.com/FDH2/UxPlay/tree/$UXPLAY_COMMIT"
  echo
  echo "Os demais vêm dos pacotes do MSYS2 (UCRT64). A receita e o código de cada pacote estão em"
  echo "https://github.com/msys2/MINGW-packages e os arquivos-fonte em https://repo.msys2.org/mingw/sources/."
  echo
  for pacote in $pacotes; do
    info="$(pacman -Qi "$pacote")"
    versao="$(sed -n 's/^Version *: *//p' <<<"$info" | head -1)"
    licenca="$(sed -n 's/^Licenses *: *//p' <<<"$info" | head -1)"
    pagina="$(sed -n 's/^URL *: *//p' <<<"$info" | head -1)"
    echo "${pacote#mingw-w64-ucrt-x86_64-} $versao · $licenca · $pagina"
    echo "    pacote: https://packages.msys2.org/packages/$pacote"
  done
} > "$DESTINO/AVISOS-DE-TERCEIROS.txt"

cp "$RAIZ/LICENSE" "$DESTINO/LICENSE"
cp "$RAIZ/windows/LEIA-ME.txt" "$DESTINO/LEIA-ME.txt"

echo "${#bibliotecas[@]} bibliotecas, ${#origens_plugins[@]} plugins, $(du -sh "$DESTINO" | cut -f1) em $DESTINO"
