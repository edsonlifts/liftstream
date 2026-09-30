#!/bin/zsh
# Prova que a cópia de dist/teste roda sem Homebrew: o sistema proíbe a leitura de /opt/homebrew
# e /usr/local durante todos os comandos, como no Mac de quem recebe o app.
# Rode ./empacotar.sh teste antes.
set -uo pipefail
cd "${0:A:h}"

A="$PWD/dist/teste/Liftstream.app/Contents"
[[ -d "$A" ]] || { echo "Rode ./empacotar.sh teste antes."; exit 1; }
T=$(mktemp -d)
cat > "$T/perfil.sb" <<'EOF'
(version 1)
(allow default)
(deny file-read* (subpath "/opt/homebrew"))
(deny file-read* (subpath "/usr/local"))
EOF
sem_brew=(sandbox-exec -f "$T/perfil.sb")

# O mesmo ambiente que o app monta para o UxPlay (ambienteEmbutido em Liftstream.swift).
export GST_PLUGIN_SYSTEM_PATH_1_0="$A/Helpers/plugins" GST_PLUGIN_PATH_1_0="" \
  GST_PLUGIN_SCANNER="$A/Helpers/gst-plugin-scanner" GST_REGISTRY_1_0="$T/registro.bin"
gl=("$A/Helpers/gst-launch-1.0")
falhas=0

confere() {  # confere "nome" comando...
  local nome=$1; shift
  local saida; saida=$("$@" 2>&1); local rc=$?
  if [[ $rc -eq 0 && "$saida" == *"Execution ended"* ]]; then
    echo "ok     $nome"
  else
    echo "FALHOU $nome"; echo "$saida" | tail -8; falhas=$((falhas + 1))
  fi
}

if "${sem_brew[@]}" /bin/ls /opt/homebrew/bin >/dev/null 2>&1; then
  echo "o bloqueio do Homebrew não funcionou; o teste não vale"; exit 1
fi
echo "ok     Homebrew bloqueado para estes testes"

# Decodificação de vídeo como o UxPlay faz (decodebin), e o trecho do app (-vs) até o JPEG multipart.
confere "vídeo H.264 -> JPEG" "${sem_brew[@]}" "${gl[@]}" videotestsrc num-buffers=60 ! video/x-raw,width=590,height=1280 \
  ! vtenc_h264 ! h264parse ! decodebin ! videoconvert ! videoscale \
  ! queue leaky=downstream max-size-buffers=2 ! jpegenc quality=85 ! multipartmux boundary=espelhopip ! fakesink
confere "áudio AAC decodificado" "${sem_brew[@]}" "${gl[@]}" audiotestsrc num-buffers=80 ! audioconvert ! avenc_aac ! aacparse \
  ! avdec_aac ! audioconvert ! audioresample quality=10 ! volume ! level ! fakesink
# Gravação: o mesmo mp4mux do UxPlay, com vídeo e áudio.
confere "gravação MP4" "${sem_brew[@]}" "${gl[@]}" -e videotestsrc num-buffers=90 ! vtenc_h264 ! h264parse ! queue ! mux. \
  audiotestsrc num-buffers=90 ! avenc_aac ! aacparse ! queue ! mux. \
  mp4mux name=mux fragment-duration=2000 fragment-mode=first-moov-then-finalise ! filesink location="$T/teste.mp4"
[[ -s "$T/teste.mp4" ]] && echo "ok     arquivo MP4 tem $(du -h "$T/teste.mp4" | cut -f1)" || { echo "FALHOU MP4 vazio"; falhas=$((falhas + 1)); }

# O receptor inteiro: sobe, inicia todos os pipelines e abre a porta AirPlay.
# O tcpclientsink conecta ao subir, então alguém precisa estar ouvindo (no app é o próprio Liftstream).
nc -l 127.0.0.1 7179 > /dev/null 2>&1 &
ouvinte=$!
"${sem_brew[@]}" "$A/Helpers/uxplay" -n "Teste PIP" -nh -p 7400 -m 02:45:50:49:50:99 -fps 60 -vsync no -d 1 \
  -vs "queue leaky=downstream max-size-buffers=2 ! jpegenc quality=85 ! multipartmux boundary=espelhopip ! tcpclientsink host=127.0.0.1 port=7179" \
  > "$T/uxplay.log" 2>&1 &
pid=$!
sleep 6
if kill -0 $pid 2>/dev/null; then
  echo "ok     UxPlay ficou de pé"
  lsof -nP -a -p $pid -iTCP -sTCP:LISTEN >/dev/null 2>&1 && echo "ok     porta AirPlay aberta" || { echo "FALHOU porta AirPlay fechada"; falhas=$((falhas + 1)); }
else
  echo "FALHOU UxPlay caiu"; falhas=$((falhas + 1))
fi
kill $pid $ouvinte 2>/dev/null; wait $pid $ouvinte 2>/dev/null
if grep -i -E "missing|cannot|erro|error|failed|not found|no element" "$T/uxplay.log" >/dev/null; then
  echo "AVISO  o registro do UxPlay tem estas linhas:"; grep -i -E "missing|cannot|erro|error|failed|not found|no element" "$T/uxplay.log" | head
fi

[[ $falhas -eq 0 ]] && echo "TUDO OK" || { echo "$falhas falha(s)"; exit 1; }
