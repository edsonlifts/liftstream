#!/bin/zsh
# Gera windows/liftstream.ico a partir do mesmo desenho do ícone do Mac (icone.swift).
# O Mac deixa margem transparente ao redor (grade do macOS); no Windows o ícone vai sem ela.
set -euo pipefail
cd "${0:A:h}/.."
T=$(mktemp -d)
swift icone.swift "$T/x.icns" "$T/1024.png"
sips -c 824 824 "$T/1024.png" --out "$T/cortado.png" >/dev/null
for n in 16 24 32 48 64 128 256; do sips -z $n $n "$T/cortado.png" --out "$T/$n.png" >/dev/null; done
python3 - "$T" windows/liftstream.ico <<'PY'
import struct, sys
pasta, saida = sys.argv[1], sys.argv[2]
tamanhos = [16, 24, 32, 48, 64, 128, 256]
pngs = [open(f"{pasta}/{n}.png", "rb").read() for n in tamanhos]
cabecalho = struct.pack("<HHH", 0, 1, len(tamanhos))
deslocamento = 6 + 16 * len(tamanhos)
entradas, dados = b"", b""
for n, png in zip(tamanhos, pngs):
    lado = 0 if n >= 256 else n
    entradas += struct.pack("<BBBBHHII", lado, lado, 0, 0, 1, 32, len(png), deslocamento + len(dados))
    dados += png
open(saida, "wb").write(cabecalho + entradas + dados)
PY
echo "Pronto: windows/liftstream.ico ($(du -h windows/liftstream.ico | cut -f1))"
