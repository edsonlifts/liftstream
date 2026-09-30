import AppKit
import ImageIO
import Network

let nomeAirPlay = "Liftstream"
let portaQuadros: UInt16 = 7171
let portaAirPlay = "7300"
let macFixo = "02:45:50:49:50:01"
let registro = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Liftstream.log")

// O UxPlay recebe o AirPlay e manda cada quadro como JPEG (multipart) por TCP local para cá.
final class ReceptorDeQuadros {
    var aoReceber: ((CGImage) -> Void)?
    var aoMudarConexao: ((Bool) -> Void)?

    private var ouvinte: NWListener?
    private var conexao: NWConnection?
    private var buffer = Data()
    private let fila = DispatchQueue(label: "espelho.quadros")
    private let filaDecodificacao = DispatchQueue(label: "espelho.decodificacao")
    private var decodificando = false
    private var pendente: Data?
    private let fimDoCabecalho = Data("\r\n\r\n".utf8)

    // O UxPlay conecta assim que parte, então ele só pode ser iniciado depois que a porta estiver aberta.
    func iniciar(aoFicarPronto: @escaping (Error?) -> Void) {
        fila.async { self.abrirPorta(tentativa: 1, aoFicarPronto: aoFicarPronto) }
    }

    private func abrirPorta(tentativa: Int, aoFicarPronto: @escaping (Error?) -> Void) {
        let parametros = NWParameters.tcp
        parametros.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: portaQuadros)!)
        parametros.allowLocalEndpointReuse = true
        let tentarDeNovo: (Error) -> Void = { erro in
            if tentativa >= 10 {
                DispatchQueue.main.async { aoFicarPronto(erro) }
            } else {
                self.fila.asyncAfter(deadline: .now() + 1) { self.abrirPorta(tentativa: tentativa + 1, aoFicarPronto: aoFicarPronto) }
            }
        }
        let ouvinte: NWListener
        do {
            ouvinte = try NWListener(using: parametros)
        } catch {
            tentarDeNovo(error)
            return
        }
        ouvinte.newConnectionHandler = { [weak self] c in self?.aceitar(c) }
        ouvinte.stateUpdateHandler = { [weak ouvinte] estado in
            switch estado {
            case .ready:
                DispatchQueue.main.async { aoFicarPronto(nil) }
            case .failed(let erro):
                ouvinte?.cancel()
                tentarDeNovo(erro)
            default: break
            }
        }
        ouvinte.start(queue: fila)
        self.ouvinte = ouvinte
    }

    private func aceitar(_ c: NWConnection) {
        conexao?.cancel()
        conexao = c
        buffer.removeAll()
        pendente = nil
        c.stateUpdateHandler = { [weak self, weak c] estado in
            guard let self, let c, self.conexao === c else { return }
            switch estado {
            case .ready: self.avisar(true)
            case .failed, .cancelled:
                self.conexao = nil
                self.avisar(false)
            default: break
            }
        }
        c.start(queue: fila)
        receber(c)
    }

    private func avisar(_ conectado: Bool) {
        DispatchQueue.main.async { self.aoMudarConexao?(conectado) }
    }

    private func receber(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] dados, _, terminou, erro in
            guard let self, self.conexao === c else { return }
            if let dados {
                self.buffer.append(dados)
                self.extrairQuadros()
            }
            if terminou || erro != nil {
                c.cancel()
                return
            }
            self.receber(c)
        }
    }

    private func extrairQuadros() {
        var ultimo: Data?
        while let fim = buffer.range(of: fimDoCabecalho) {
            let cabecalho = String(decoding: buffer[buffer.startIndex..<fim.lowerBound], as: UTF8.self)
            guard let tamanho = tamanhoDoConteudo(cabecalho) else {
                buffer.removeSubrange(buffer.startIndex..<fim.upperBound)
                continue
            }
            guard buffer.distance(from: fim.upperBound, to: buffer.endIndex) >= tamanho else { break }
            let fimDoQuadro = buffer.index(fim.upperBound, offsetBy: tamanho)
            ultimo = buffer.subdata(in: fim.upperBound..<fimDoQuadro)
            buffer.removeSubrange(buffer.startIndex..<fimDoQuadro)
        }
        if buffer.count > 32 << 20 { buffer.removeAll() }
        if let ultimo { decodificar(ultimo) }
    }

    private func tamanhoDoConteudo(_ cabecalho: String) -> Int? {
        for linha in cabecalho.split(whereSeparator: \.isNewline) {
            let partes = linha.split(separator: ":", maxSplits: 1)
            if partes.count == 2, partes[0].lowercased() == "content-length" {
                return Int(partes[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    // Se a decodificação atrasar, pula quadros e mostra sempre o mais recente.
    private func decodificar(_ jpeg: Data) {
        pendente = jpeg
        guard !decodificando else { return }
        decodificando = true
        proximo()
    }

    private func proximo() {
        guard let jpeg = pendente else {
            decodificando = false
            return
        }
        pendente = nil
        filaDecodificacao.async {
            let opcoes = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            if let fonte = CGImageSourceCreateWithData(jpeg as CFData, nil),
               let imagem = CGImageSourceCreateImageAtIndex(fonte, 0, opcoes) {
                DispatchQueue.main.async { self.aoReceber?(imagem) }
            }
            self.fila.async { self.proximo() }
        }
    }
}

final class PainelPIP: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// Cores da Lifts (skill lifts-design, fundação §2.1).
let liftsDeep = NSColor(srgbRed: 0x06 / 255, green: 0x0F / 255, blue: 0x1A / 255, alpha: 1)
let liftsLime = NSColor(srgbRed: 0xCC / 255, green: 0xCB / 255, blue: 0x3F / 255, alpha: 1)

final class VistaEspelho: NSView {
    private let aviso = NSTextField(wrappingLabelWithString: "")
    private let logo = NSImageView()
    private let pilha = NSStackView()
    private let camadaImagem = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = liftsDeep.cgColor
        camadaImagem.contentsGravity = .resizeAspect
        camadaImagem.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(camadaImagem)

        aviso.alignment = .center
        aviso.maximumNumberOfLines = 0

        if let arquivo = Bundle.main.url(forResource: "logo-horizontal", withExtension: "png"), let imagem = NSImage(contentsOf: arquivo) {
            logo.image = imagem
            logo.imageScaling = .scaleProportionallyUpOrDown
            logo.setAccessibilityLabel("Clínica Lifts")
            logo.translatesAutoresizingMaskIntoConstraints = false
            logo.widthAnchor.constraint(equalToConstant: 96).isActive = true
            logo.heightAnchor.constraint(equalTo: logo.widthAnchor, multiplier: imagem.size.height / imagem.size.width).isActive = true
            pilha.addArrangedSubview(logo)
        }
        pilha.addArrangedSubview(aviso)
        pilha.orientation = .vertical
        pilha.alignment = .centerX
        pilha.spacing = 22
        pilha.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pilha)
        NSLayoutConstraint.activate([
            pilha.centerXAnchor.constraint(equalTo: centerXAnchor),
            pilha.centerYAnchor.constraint(equalTo: centerYAnchor),
            pilha.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        camadaImagem.frame = bounds
    }

    // Branco sobre o deep fica acima do piso de .50 da Lifts; o nome do programa vai em lime.
    func mostrarAviso(_ texto: String) {
        let centro = NSMutableParagraphStyle()
        centro.alignment = .center
        centro.lineSpacing = 3
        let corpo = NSMutableAttributedString(string: texto, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.85),
            .paragraphStyle: centro,
        ])
        var inicio = texto.startIndex
        while let achado = texto.range(of: nomeAirPlay, range: inicio..<texto.endIndex) {
            corpo.addAttributes([.font: NSFont.systemFont(ofSize: 13, weight: .heavy), .foregroundColor: liftsLime],
                                range: NSRange(achado, in: texto))
            inicio = achado.upperBound
        }
        aviso.attributedStringValue = corpo
        pilha.isHidden = false
        camadaImagem.contents = nil
    }

    func mostrar(_ imagem: CGImage) {
        pilha.isHidden = true
        camadaImagem.contents = imagem
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        window?.standardWindowButton(.closeButton)?.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        window?.standardWindowButton(.closeButton)?.isHidden = true
    }
}

// Avisa quando há versão nova no GitHub Releases. Só consulta e abre a página de download; não instala nada.
let repositorio = "edsonlifts/liftstream"

struct VersaoNova {
    let numero: String
    let notas: String
    let endereco: URL
}

enum Atualizacoes {
    static var versaoAtual: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // 1.10 é maior que 1.9, e 1.0 é igual a 1.0.0.
    static func ehMaior(_ nova: String, que atual: String) -> Bool {
        func partes(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = partes(nova), b = partes(atual)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // Sucesso com nil quer dizer "está em dia"; falha é rede fora do ar ou resposta estranha.
    static func consultar(_ fim: @escaping (Result<VersaoNova?, Error>) -> Void) {
        // LIFTSTREAM_ATUALIZACAO_URL existe para testar com uma resposta local.
        let texto = ProcessInfo.processInfo.environment["LIFTSTREAM_ATUALIZACAO_URL"]
            ?? "https://api.github.com/repos/\(repositorio)/releases/latest"
        guard let url = URL(string: texto) else { return fim(.failure(URLError(.badURL))) }
        var pedido = URLRequest(url: url, timeoutInterval: 10)
        pedido.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        pedido.setValue("Liftstream/\(versaoAtual)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: pedido) { dados, resposta, erro in
            if let erro { return fim(.failure(erro)) }
            guard (resposta as? HTTPURLResponse)?.statusCode == 200, let dados,
                  let json = try? JSONSerialization.jsonObject(with: dados) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return fim(.failure(URLError(.badServerResponse))) }
            guard ehMaior(tag, que: versaoAtual) else { return fim(.success(nil)) }
            // O zip direto é um clique só; sem ele, a página do release.
            let arquivos = json["assets"] as? [[String: Any]] ?? []
            let zip = arquivos.first { ($0["name"] as? String) == "Liftstream.zip" }?["browser_download_url"] as? String
            guard let destino = (zip ?? json["html_url"] as? String).flatMap(URL.init(string:)), destino.scheme == "https" else {
                return fim(.failure(URLError(.badServerResponse)))
            }
            fim(.success(VersaoNova(numero: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                                    notas: (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                    endereco: destino)))
        }.resume()
    }
}

final class Aplicativo: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var painel: PainelPIP!
    private let vista = VistaEspelho(frame: .zero)
    private let receptor = ReceptorDeQuadros()
    private var uxplay: Process?
    private var encerrando = false
    private var reinicios = 0
    private var tamanhoDoQuadro = CGSize.zero
    private var ladoMaior: CGFloat = 640
    private var gravando = false
    private var reiniciandoDeProposito = false

    private let textoEspera = "No iPhone, abra a Central de Controle,\ntoque em Espelhar Tela e escolha\n“\(nomeAirPlay)”."

    func applicationDidFinishLaunching(_ notification: Notification) {
        montarMenu()
        montarPainel()
        receptor.aoReceber = { [weak self] imagem in self?.mostrar(imagem) }
        receptor.aoMudarConexao = { [weak self] conectado in self?.conexaoMudou(conectado) }
        receptor.iniciar { [weak self] erro in
            guard let self else { return }
            if let erro {
                self.vista.mostrarAviso("Não consegui abrir a porta \(portaQuadros).\n\(erro.localizedDescription)")
            } else {
                self.iniciarUxPlay()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.verificarAtualizacao(manual: false) }
    }

    // MARK: Atualização

    private var alertaAberto = false

    // Sozinho, consulta no máximo a cada 20 horas e só fala se houver versão nova; pelo menu, sempre responde.
    private func verificarAtualizacao(manual: Bool) {
        let chave = "ultimaChecagem"
        if !manual, Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: chave) < 20 * 3600 { return }
        Atualizacoes.consultar { [weak self] resultado in
            DispatchQueue.main.async {
                guard let self else { return }
                switch resultado {
                case .success(let nova):
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: chave)
                    if let nova {
                        self.oferecer(nova)
                    } else if manual {
                        self.avisar("Você está na versão mais recente", "O Liftstream \(Atualizacoes.versaoAtual) é o último.")
                    }
                case .failure:
                    if manual { self.avisar("Não consegui verificar", "Confira a conexão com a internet e tente de novo.") }
                }
            }
        }
    }

    // O aviso é uma folha presa à janela flutuante: ela está sempre à vista, ao contrário de um alerta solto,
    // que o sistema esconde enquanto este app não é o ativo (e ele quase nunca é, porque a janela não rouba o foco).
    private func oferecer(_ nova: VersaoNova) {
        guard !alertaAberto else { return }
        alertaAberto = true
        let alerta = NSAlert()
        alerta.messageText = "Tem uma versão nova do Liftstream"
        let notas = nova.notas.isEmpty ? "" : "\n\n" + String(nova.notas.prefix(400))
        alerta.informativeText = "Você está na \(Atualizacoes.versaoAtual) e a nova é a \(nova.numero).\(notas)"
        alerta.addButton(withTitle: "Baixar")
        alerta.addButton(withTitle: "Agora não")
        alerta.beginSheetModal(for: painel) { [weak self] resposta in
            self?.alertaAberto = false
            if resposta == .alertFirstButtonReturn { NSWorkspace.shared.open(nova.endereco) }
        }
    }

    private func avisar(_ titulo: String, _ texto: String) {
        guard !alertaAberto else { return }
        alertaAberto = true
        let alerta = NSAlert()
        alerta.messageText = titulo
        alerta.informativeText = texto
        alerta.beginSheetModal(for: painel) { [weak self] _ in self?.alertaAberto = false }
    }

    @objc private func verificarPeloMenu() { verificarAtualizacao(manual: true) }

    func applicationWillTerminate(_ notification: Notification) {
        encerrando = true
        uxplay?.terminate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        painel.orderFrontRegardless()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    func windowDidResize(_ notification: Notification) {
        ladoMaior = max(painel.frame.width, painel.frame.height)
    }

    // MARK: UxPlay

    private func iniciarUxPlay() {
        let binario = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/uxplay")
        encerrarOrfaos(binario.path)

        FileManager.default.createFile(atPath: registro.path, contents: nil)
        let arquivoRegistro = try? FileHandle(forWritingTo: registro)

        var argumentos = [
            "-n", nomeAirPlay, "-nh",
            "-p", portaAirPlay,
            "-m", macFixo,
            "-fps", "60",
            "-vsync", "no",
            "-d", "1",
            "-vs", "queue leaky=downstream max-size-buffers=2 ! jpegenc quality=85 ! multipartmux boundary=espelhopip ! tcpclientsink host=127.0.0.1 port=\(portaQuadros)",
        ]
        if gravando {
            let pasta = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Liftstream")
            try? FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
            let formato = DateFormatter()
            formato.dateFormat = "yyyy-MM-dd HH.mm.ss"
            argumentos += ["-mp4", pasta.appendingPathComponent("iPhone \(formato.string(from: Date()))").path]
        }

        // A conexão TCP dos quadros fica aberta o tempo todo; quem avisa que o iPhone saiu é o registro do UxPlay.
        let saida = Pipe()
        var resto = ""
        saida.fileHandleForReading.readabilityHandler = { [weak self] leitor in
            let dados = leitor.availableData
            guard !dados.isEmpty else {
                leitor.readabilityHandler = nil
                return
            }
            arquivoRegistro?.write(dados)
            resto += String(decoding: dados, as: UTF8.self)
            let linhas = resto.components(separatedBy: "\n")
            resto = linhas.last ?? ""
            if linhas.dropLast().contains(where: { $0.contains("Open connections: 0") }) {
                DispatchQueue.main.async { self?.iphoneSaiu() }
            }
        }

        let processo = Process()
        processo.executableURL = binario
        processo.arguments = argumentos
        if let ambiente = ambienteEmbutido() { processo.environment = ambiente }
        processo.standardOutput = saida
        processo.standardError = saida
        processo.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.uxplayParou() }
        }
        do {
            try processo.run()
            uxplay = processo
        } catch {
            vista.mostrarAviso("Não consegui iniciar o receptor AirPlay.\n\(error.localizedDescription)")
        }
    }

    // Na cópia feita por empacotar.sh o GStreamer vem dentro do app; sem ele, vale o do Homebrew.
    private func ambienteEmbutido() -> [String: String]? {
        let plugins = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/plugins")
        guard FileManager.default.fileExists(atPath: plugins.path) else { return nil }
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Liftstream")
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var ambiente = ProcessInfo.processInfo.environment
        ambiente["GST_PLUGIN_SYSTEM_PATH_1_0"] = plugins.path
        ambiente["GST_PLUGIN_PATH_1_0"] = ""
        ambiente["GST_PLUGIN_SCANNER"] = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/gst-plugin-scanner").path
        ambiente["GST_REGISTRY_1_0"] = cache.appendingPathComponent("registro-gstreamer.bin").path
        return ambiente
    }

    // Um UxPlay que sobrou de uma execução interrompida seguraria as portas.
    private func encerrarOrfaos(_ caminho: String) {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", caminho]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    private func uxplayParou() {
        if encerrando { return }
        if reiniciandoDeProposito {
            reiniciandoDeProposito = false
            iniciarUxPlay()
            return
        }
        tamanhoDoQuadro = .zero
        if reinicios < 3 {
            reinicios += 1
            vista.mostrarAviso("Reiniciando o receptor…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.iniciarUxPlay() }
        } else {
            vista.mostrarAviso("O receptor AirPlay parou.\nDetalhes em ~/Library/Logs/Liftstream.log")
        }
    }

    // MARK: Janela

    private func montarPainel() {
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let tamanho = NSSize(width: 295, height: 640)
        let quadro = NSRect(x: area.maxX - tamanho.width - 24, y: area.maxY - tamanho.height - 24,
                            width: tamanho.width, height: tamanho.height)
        painel = PainelPIP(contentRect: quadro,
                           styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        painel.title = nomeAirPlay
        painel.titleVisibility = .hidden
        painel.titlebarAppearsTransparent = true
        painel.isMovableByWindowBackground = true
        painel.hidesOnDeactivate = false
        painel.becomesKeyOnlyIfNeeded = true
        painel.level = .floating
        painel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        painel.minSize = NSSize(width: 120, height: 120)
        painel.delegate = self
        painel.contentView = vista
        for botao in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            painel.standardWindowButton(botao)?.isHidden = true
        }
        vista.mostrarAviso(textoEspera)
        painel.orderFrontRegardless()
    }

    private func conexaoMudou(_ conectado: Bool) {
        if !conectado { iphoneSaiu() }
    }

    private func iphoneSaiu() {
        tamanhoDoQuadro = .zero
        vista.mostrarAviso(textoEspera)
    }

    private func mostrar(_ imagem: CGImage) {
        reinicios = 0
        let tamanho = CGSize(width: imagem.width, height: imagem.height)
        if tamanho != tamanhoDoQuadro {
            tamanhoDoQuadro = tamanho
            ajustarJanela()
        }
        vista.mostrar(imagem)
    }

    // Mantém o canto superior direito no lugar ao girar o iPhone ou trocar o tamanho.
    private func ajustarJanela() {
        guard tamanhoDoQuadro.width > 0, tamanhoDoQuadro.height > 0 else { return }
        let proporcao = tamanhoDoQuadro.width / tamanhoDoQuadro.height
        let novo = proporcao < 1
            ? NSSize(width: (ladoMaior * proporcao).rounded(), height: ladoMaior)
            : NSSize(width: ladoMaior, height: (ladoMaior / proporcao).rounded())
        let atual = painel.frame
        var origem = NSPoint(x: atual.maxX - novo.width, y: atual.maxY - novo.height)
        if let area = (painel.screen ?? NSScreen.main)?.visibleFrame {
            origem.x = min(max(origem.x, area.minX), area.maxX - novo.width)
            origem.y = min(max(origem.y, area.minY), area.maxY - novo.height)
        }
        painel.contentAspectRatio = tamanhoDoQuadro
        painel.setFrame(NSRect(origin: origem, size: novo), display: true)
    }

    // MARK: Menu

    private func montarMenu() {
        let principal = NSMenu()

        let menuApp = NSMenu()
        menuApp.addItem(withTitle: "Sobre o \(nomeAirPlay)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menuApp.addItem(withTitle: "Verificar atualizações…", action: #selector(verificarPeloMenu), keyEquivalent: "")
        menuApp.addItem(.separator())
        menuApp.addItem(withTitle: "Ocultar \(nomeAirPlay)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menuApp.addItem(.separator())
        menuApp.addItem(withTitle: "Sair do \(nomeAirPlay)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let itemApp = NSMenuItem()
        itemApp.submenu = menuApp
        principal.addItem(itemApp)

        let menuJanela = NSMenu(title: "Janela")
        let naFrente = NSMenuItem(title: "Sempre na frente", action: #selector(alternarNaFrente(_:)), keyEquivalent: "t")
        naFrente.state = .on
        menuJanela.addItem(naFrente)
        menuJanela.addItem(NSMenuItem(title: "Deixar os cliques passarem", action: #selector(alternarCliques(_:)), keyEquivalent: "k"))
        menuJanela.addItem(.separator())

        let menuTamanho = NSMenu()
        for (nome, lado, tecla) in [("Pequeno", 480, "1"), ("Médio", 640, "2"), ("Grande", 900, "3")] {
            let item = NSMenuItem(title: nome, action: #selector(escolherTamanho(_:)), keyEquivalent: tecla)
            item.tag = lado
            menuTamanho.addItem(item)
        }
        let itemTamanho = NSMenuItem(title: "Tamanho", action: nil, keyEquivalent: "")
        itemTamanho.submenu = menuTamanho
        menuJanela.addItem(itemTamanho)

        let menuOpacidade = NSMenu()
        for porcento in [100, 85, 70, 50] {
            let item = NSMenuItem(title: "\(porcento)%", action: #selector(escolherOpacidade(_:)), keyEquivalent: "")
            item.tag = porcento
            item.state = porcento == 100 ? .on : .off
            menuOpacidade.addItem(item)
        }
        let itemOpacidade = NSMenuItem(title: "Opacidade", action: nil, keyEquivalent: "")
        itemOpacidade.submenu = menuOpacidade
        menuJanela.addItem(itemOpacidade)

        let itemJanela = NSMenuItem()
        itemJanela.submenu = menuJanela
        principal.addItem(itemJanela)

        let menuGravar = NSMenu(title: "Gravar")
        menuGravar.addItem(NSMenuItem(title: "Gravar em MP4 (com som do iPhone)", action: #selector(alternarGravacao(_:)), keyEquivalent: "r"))
        menuGravar.addItem(NSMenuItem(title: "Abrir pasta das gravações", action: #selector(abrirGravacoes), keyEquivalent: ""))
        let itemGravar = NSMenuItem()
        itemGravar.submenu = menuGravar
        principal.addItem(itemGravar)

        NSApp.mainMenu = principal
    }

    // O UxPlay só aceita -mp4 na partida: ligar ou desligar reinicia o receptor e o iPhone precisa espelhar de novo.
    @objc private func alternarGravacao(_ item: NSMenuItem) {
        gravando.toggle()
        item.state = gravando ? .on : .off
        reiniciandoDeProposito = true
        iphoneSaiu()
        vista.mostrarAviso((gravando ? "Gravação ligada." : "Gravação desligada.") + "\nEspelhe de novo pelo iPhone.\n\n" + textoEspera)
        uxplay?.terminate()
    }

    @objc private func abrirGravacoes() {
        let pasta = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Liftstream")
        try? FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        NSWorkspace.shared.open(pasta)
    }

    @objc private func alternarNaFrente(_ item: NSMenuItem) {
        item.state = item.state == .on ? .off : .on
        painel.level = item.state == .on ? .floating : .normal
    }

    @objc private func alternarCliques(_ item: NSMenuItem) {
        item.state = item.state == .on ? .off : .on
        painel.ignoresMouseEvents = item.state == .on
    }

    @objc private func escolherTamanho(_ item: NSMenuItem) {
        ladoMaior = CGFloat(item.tag)
        if tamanhoDoQuadro == .zero {
            let atual = painel.frame
            let novo = NSSize(width: (ladoMaior * 0.46).rounded(), height: ladoMaior)
            painel.setFrame(NSRect(x: atual.maxX - novo.width, y: atual.maxY - novo.height,
                                   width: novo.width, height: novo.height), display: true)
        } else {
            ajustarJanela()
        }
    }

    @objc private func escolherOpacidade(_ item: NSMenuItem) {
        item.menu?.items.forEach { $0.state = $0 === item ? .on : .off }
        painel.alphaValue = CGFloat(item.tag) / 100
    }
}

let app = NSApplication.shared
let delegado = Aplicativo()
app.delegate = delegado
app.setActivationPolicy(.regular)
app.run()
