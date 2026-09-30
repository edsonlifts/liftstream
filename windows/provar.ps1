# Prova a cópia de dist/teste como se fosse num PC qualquer: sem o MSYS2 no PATH.
# Roda no CI (windows-latest) depois do empacotar-msys2.sh ... teste.
#   provar.ps1 -Pasta <dist\teste> -Saida <pasta para imagens e registros>
param(
    [Parameter(Mandatory = $true)][string]$Pasta,
    [Parameter(Mandatory = $true)][string]$Saida
)
$ErrorActionPreference = 'Continue'
$script:falhas = 0
New-Item -ItemType Directory -Force -Path $Saida | Out-Null

function Ok($texto) { Write-Host "ok     $texto" }
function Falhou($texto, $detalhe) {
    Write-Host "FALHOU $texto"
    if ($detalhe) { Write-Host ($detalhe | Out-String) }
    $script:falhas++
}

# O mesmo ambiente que o app monta para o UxPlay (ProcessoUxPlay.cs). O PATH é só o que um PC comum tem.
$env:GST_PLUGIN_SYSTEM_PATH_1_0 = "$Pasta\plugins"
Remove-Item Env:GST_PLUGIN_PATH_1_0 -ErrorAction SilentlyContinue
Remove-Item Env:GST_PLUGIN_PATH -ErrorAction SilentlyContinue
$env:GST_PLUGIN_SCANNER = "$Pasta\gst-plugin-scanner.exe"
$env:GST_REGISTRY_1_0 = "$Saida\registro-gstreamer.bin"
$env:PATH = "$Pasta;$env:SystemRoot\System32;$env:SystemRoot"

$gl = "$Pasta\gst-launch-1.0.exe"
$gi = "$Pasta\gst-inspect-1.0.exe"

# Roda um pipeline do gst-launch pelo cmd (o PowerShell estraga vírgulas e aspas) e devolve a saída.
# A linha vai crua, dentro de um par extra de aspas, que é o que o cmd /c espera quando o caminho vem entre aspas.
function Gst($pipeline, $pastaDeTrabalho) {
    if (-not $pastaDeTrabalho) { $pastaDeTrabalho = $Pasta }
    $info = [System.Diagnostics.ProcessStartInfo]::new('cmd.exe')
    $info.Arguments = '/c ""' + $gl + '" ' + $pipeline + ' 2>&1"'
    $info.WorkingDirectory = $pastaDeTrabalho
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.CreateNoWindow = $true
    $processo = [System.Diagnostics.Process]::Start($info)
    $saida = $processo.StandardOutput.ReadToEnd()
    if (-not $processo.WaitForExit(180000)) { $processo.Kill() }
    return $saida
}

function Confere($nome, $pipeline, $pastaDeTrabalho) {
    $saida = Gst $pipeline $pastaDeTrabalho
    if ($saida -match 'Execution ended') { Ok $nome } else { Falhou $nome ($saida -split "`n" | Select-Object -Last 12) }
    return $saida
}

# 1) Os elementos que o UxPlay e o app usam.
$elementos = 'appsrc queue h264parse h265parse decodebin playbin3 videoconvert videoscale videoflip jpegenc jpegdec multipartmux tcpclientsink imagefreeze textoverlay avdec_aac avdec_alac avdec_h264 audioconvert audioresample volume level autoaudiosink aacparse mp4mux filesink'.Split(' ')
$faltam = @()
foreach ($e in $elementos) {
    & $gi $e *> $null
    if ($LASTEXITCODE -ne 0) { $faltam += $e }
}
if ($faltam.Count -eq 0) { Ok "todos os $($elementos.Count) elementos existem" } else { Falhou "faltam elementos: $($faltam -join ', ')" }
$sons = @('directsoundsink', 'wasapisink', 'wasapi2sink') | Where-Object { & $gi $_ *> $null; $LASTEXITCODE -eq 0 }
if ($sons) { Ok "saída de áudio: $($sons -join ', ')" } else { Falhou "nenhuma saída de áudio do Windows" }

# 2) Decodificação como o UxPlay faz (decodebin) até o JPEG multipart do app.
$saida = Confere 'vídeo H.264 -> JPEG' '-v videotestsrc num-buffers=60 ! video/x-raw,width=590,height=1280 ! x264enc tune=zerolatency ! h264parse ! decodebin ! videoconvert ! videoscale ! queue leaky=downstream max-size-buffers=2 ! jpegenc quality=85 ! multipartmux boundary=espelhopip ! fakesink'
$decodificador = ([regex]::Matches($saida, '(avdec_h264|d3d11h264dec|d3d12h264dec|mfh264dec)') | Select-Object -First 1).Value
Write-Host "       decodebin escolheu: $decodificador"
Confere 'áudio AAC decodificado' 'audiotestsrc num-buffers=80 ! audioconvert ! avenc_aac ! aacparse ! avdec_aac ! audioconvert ! audioresample quality=10 ! volume ! level ! fakesink' | Out-Null

# 3) Gravação MP4 com o mesmo mp4mux do UxPlay, numa pasta com espaço no nome e caminho relativo
#    (o UxPlay cola o nome sem aspas no pipeline; ver ProcessoUxPlay.cs).
$comEspaco = "$Saida\pasta com espaço"
New-Item -ItemType Directory -Force -Path $comEspaco | Out-Null
Confere 'gravação MP4' '-e videotestsrc num-buffers=90 ! x264enc tune=zerolatency ! h264parse ! queue ! mux. audiotestsrc num-buffers=90 ! avenc_aac ! aacparse ! queue ! mux. mp4mux name=mux fragment-duration=2000 fragment-mode=first-moov-then-finalise ! filesink location=iPhone_teste.mp4' $comEspaco | Out-Null
$mp4 = Get-Item "$comEspaco\iPhone_teste.mp4" -ErrorAction SilentlyContinue
if ($mp4 -and $mp4.Length -gt 10000) { Ok "arquivo MP4 tem $([math]::Round($mp4.Length / 1KB)) KB" } else { Falhou "MP4 vazio ou ausente" }

# 4) O UxPlay sozinho: sobe, abre a porta AirPlay e aceita -mp4 com pasta de trabalho com espaço.
#    O tcpclientsink conecta ao subir, então alguém precisa estar ouvindo (no app é o próprio Liftstream).
function TestaUxPlay($rotulo, $porta, $extra, $pastaDeTrabalho, $registro) {
    $ouvinte = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 7179)
    $ouvinte.Start()
    $linhaDeComando = "-n `"Teste PIP`" -nh -p $porta -m 02:45:50:49:50:99 -d 1 $extra -vs `"queue ! jpegenc ! multipartmux ! tcpclientsink host=127.0.0.1 port=7179`""
    $p = Start-Process -FilePath "$Pasta\uxplay.exe" -ArgumentList $linhaDeComando -WorkingDirectory $pastaDeTrabalho -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput "$Saida\$registro.out.log" -RedirectStandardError "$Saida\$registro.err.log"
    Start-Sleep -Seconds 7
    $vivo = -not $p.HasExited
    $portas = @()
    if ($vivo) { $portas = Get-NetTCPConnection -State Listen -OwningProcess $p.Id -ErrorAction SilentlyContinue | ForEach-Object { $_.LocalPort } | Sort-Object -Unique }
    if ($vivo) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    $ouvinte.Stop()
    if ($vivo) { Ok "$rotulo: UxPlay de pé" } else { Falhou "$rotulo: UxPlay caiu (código $($p.ExitCode))" ((Get-Content "$Saida\$registro.out.log", "$Saida\$registro.err.log" -ErrorAction SilentlyContinue) | Select-Object -Last 15) }
    if ($vivo) { if ($portas.Count -gt 0) { Ok "$rotulo: escutando nas portas $($portas -join ', ')" } else { Falhou "$rotulo: nenhuma porta aberta" } }
}
TestaUxPlay 'UxPlay' 7400 '' $Pasta 'uxplay'
TestaUxPlay 'UxPlay com -mp4' 7410 '-mp4 iPhone_2026-09-30_15.00.00' $comEspaco 'uxplay-mp4'

# 5) O app inteiro: janela, UxPlay embutido, padrão de teste no lugar do iPhone, imagens do que ele desenha.
function RodaApp($rotulo, $pasta, $variaveis, $esperar, $alimentar) {
    New-Item -ItemType Directory -Force -Path $pasta | Out-Null
    $env:LIFTSTREAM_CAPTURA = $pasta
    foreach ($k in $variaveis.Keys) { Set-Item "Env:$k" $variaveis[$k] }
    $app = Start-Process -FilePath "$Pasta\Liftstream.exe" -PassThru
    $feeder = $null
    try {
        if ($alimentar) {
            for ($i = 0; $i -lt 60 -and -not (Test-Path "$pasta\espera.png"); $i++) { Start-Sleep -Seconds 1 }
            $feeder = Start-Process -FilePath "cmd.exe" -PassThru -WindowStyle Hidden -ArgumentList "/c `"`"$gl`" videotestsrc is-live=true pattern=ball ! video/x-raw,width=590,height=1280,framerate=30/1 ! videoconvert ! jpegenc ! multipartmux boundary=espelhopip ! tcpclientsink host=127.0.0.1 port=7171`""
        }
        for ($i = 0; $i -lt $esperar -and -not (Test-Path "$pasta\$($alimentar ? 'ok.txt' : 'atualizacao.txt')"); $i++) { Start-Sleep -Seconds 1 }
    }
    finally {
        if ($feeder) { Stop-Process -Id $feeder.Id -Force -ErrorAction SilentlyContinue; Get-Process gst-launch-1.0 -ErrorAction SilentlyContinue | Stop-Process -Force }
        if (-not $app.HasExited) { Start-Sleep -Seconds 2 }
        if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item Env:LIFTSTREAM_CAPTURA -ErrorAction SilentlyContinue
        foreach ($k in $variaveis.Keys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
    }
}

$captura = "$Saida\captura"
RodaApp 'app com quadros' $captura @{} 90 $true
foreach ($arquivo in 'espera.png', 'video.png') {
    if (Test-Path "$captura\$arquivo") { Ok "imagem $arquivo gerada" } else { Falhou "imagem $arquivo não foi gerada" (Get-ChildItem $captura -ErrorAction SilentlyContinue | Out-String) }
}
if (Test-Path "$captura\ok.txt") { Ok "app recebeu quadros do UxPlay embutido: $(Get-Content "$captura\ok.txt")" } else { Falhou "o app não mostrou nenhum quadro" (Get-Content "$captura\erro.txt" -ErrorAction SilentlyContinue) }
if (Test-Path "$captura\atualizacao.txt") { Write-Host "       aviso de versão contra o GitHub de verdade: $(Get-Content "$captura\atualizacao.txt")" }

# 6) O aviso de versão com uma resposta local que diz haver versão futura (a forma é a da API do GitHub).
$json = "$Saida\nova.json"
'{"tag_name":"v9.9.9","html_url":"https://github.com/edsonlifts/liftstream/releases/tag/v9.9.9","body":"teste","assets":[{"name":"Liftstream-Windows.zip","browser_download_url":"https://github.com/edsonlifts/liftstream/releases/download/v9.9.9/Liftstream-Windows.zip"}]}' | Set-Content -Path $json -Encoding ascii
$url = ([System.Uri]$json).AbsoluteUri
RodaApp 'aviso' "$Saida\captura-aviso" @{ LIFTSTREAM_ATUALIZACAO_URL = $url } 40 $false
$resultado = Get-Content "$Saida\captura-aviso\atualizacao.txt" -ErrorAction SilentlyContinue
if ($resultado -eq 'nova 9.9.9') { Ok "aviso de versão nova: $resultado" } else { Falhou "aviso de versão nova respondeu '$resultado'" }
$json2 = "$Saida\emdia.json"
'{"tag_name":"v0.0.1","html_url":"https://github.com/edsonlifts/liftstream/releases/tag/v0.0.1","body":"","assets":[]}' | Set-Content -Path $json2 -Encoding ascii
RodaApp 'em dia' "$Saida\captura-emdia" @{ LIFTSTREAM_ATUALIZACAO_URL = ([System.Uri]$json2).AbsoluteUri } 40 $false
$resultado = Get-Content "$Saida\captura-emdia\atualizacao.txt" -ErrorAction SilentlyContinue
if ($resultado -eq 'em dia') { Ok "app em dia não incomoda: $resultado" } else { Falhou "app em dia respondeu '$resultado'" }

# Registro do UxPlay embutido, para quem for olhar depois.
Copy-Item "$env:LOCALAPPDATA\Liftstream\Liftstream.log" "$Saida\Liftstream.log" -ErrorAction SilentlyContinue

Get-Process uxplay, Liftstream, gst-launch-1.0 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
if ($script:falhas -eq 0) { Write-Host "TUDO OK"; exit 0 } else { Write-Host "$($script:falhas) falha(s)"; exit 1 }
