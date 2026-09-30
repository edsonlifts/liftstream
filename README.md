# Liftstream

Mostra a tela do iPhone numa janela flutuante no Mac, sem cabo, e grava em MP4 com o som do iPhone. Feito pela Clínica Lifts para gravar o celular enquanto se usa o Mac.

O Mac aparece como um receptor AirPlay chamado "Liftstream". No iPhone: Central de Controle, Espelhar Tela, Liftstream.

## Baixar

[**Baixar a última versão (Liftstream.zip)**](https://github.com/edsonlifts/liftstream/releases/latest/download/Liftstream.zip)

Precisa de Mac com chip Apple (M1 ou mais novo) e macOS 26. O zip traz o app e o `LEIA-ME.txt` com o passo a passo. O app não é assinado pela Apple, então na primeira vez é preciso rodar no Terminal:

```
xattr -cr /Applications/Liftstream.app
```

## Atualizações

O app consulta os releases deste repositório no máximo uma vez por dia e avisa quando há versão nova (menu Liftstream, Verificar atualizações, consulta na hora). Ele só pergunta qual é a última versão e abre o download; não envia nada do usuário e não se instala sozinho.

## Como funciona

- `Liftstream.swift` (AppKit, arquivo único) abre um servidor TCP local e só depois inicia o [UxPlay](https://github.com/FDH2/UxPlay), que recebe o AirPlay e manda cada quadro como JPEG para o app.
- O UxPlay e o GStreamer vão dentro do app (`Contents/Helpers` e `Contents/Frameworks`), então quem recebe não precisa instalar nada.

## Compilar

Precisa do Homebrew com `gstreamer`, `libplist`, `cmake` e `pkgconf`.

```
./build.sh          # compila o UxPlay (versão fixada em UXPLAY_COMMIT) e o app, e instala em ~/Desktop
./empacotar.sh      # dist/Liftstream.zip: copia para dentro do app o que veio do Homebrew
./provar.sh         # prova a cópia com o sistema proibindo a leitura de /opt/homebrew
```

`./empacotar.sh teste` gera a cópia de teste que o `provar.sh` usa.

## Publicar uma versão nova

Suba `CFBundleShortVersionString` no `Info.plist` e rode:

```
./publicar.sh "o que mudou"
```

O script compila, prova, empacota, envia o código e cria o release com o `Liftstream.zip`. Quem já tem o app recebe o aviso na próxima abertura.

## Licenças

O Liftstream é distribuído sob a **GPL-3.0** (arquivo `LICENSE`). O zip leva o UxPlay (GPL-3.0), o GStreamer, o ffmpeg e outras bibliotecas, cada uma sob a própria licença. O arquivo `AVISOS-DE-TERCEIROS.txt`, dentro do zip, lista cada uma com a versão, a licença e o endereço do código-fonte dessa versão.

A logo da Clínica Lifts em `recursos/` é marca da clínica e não está coberta pela GPL.
