import AppKit

// Ícone do Liftstream nas cores da Lifts (skill lifts-design, fundação §2 e §4.1).
// Uso: swift icone.swift <saída.icns> [prévia.png]
let destino = CommandLine.arguments[1]
let pastaRecursos = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("recursos")
let marca = NSImage(contentsOf: pastaRecursos.appendingPathComponent("marca.png"))!

func cor(_ hex: Int, _ alfa: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alfa)
}
let deep = cor(0x060F1A), navy = cor(0x0F2638), mid = cor(0x12314A), lime = cor(0xCCCB3F)

func desenhar(_ lado: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: lado, pixelsHigh: lado, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = CGFloat(lado) / 1024

    let fundo = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s),
                             xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: deep, ending: navy)!.draw(in: fundo, angle: 90)

    // Faixa xadrez lime (a bandeirada) no topo, cortada pelo canto arredondado.
    NSGraphicsContext.saveGraphicsState()
    fundo.addClip()
    lime.setFill()
    let k = 1.5 * s, topo = 924 * s
    for n in -1..<6 {
        let x = CGFloat(n) * 120 * k + 100 * s
        let faixa = NSBezierPath()
        faixa.move(to: NSPoint(x: x + 20 * k, y: topo))
        faixa.line(to: NSPoint(x: x + 80 * k, y: topo))
        faixa.line(to: NSPoint(x: x + 60 * k, y: topo - 60 * k))
        faixa.line(to: NSPoint(x: x, y: topo - 60 * k))
        faixa.close()
        faixa.fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Janela do Mac ao fundo.
    let janela = NSBezierPath(roundedRect: NSRect(x: 180 * s, y: 250 * s, width: 560 * s, height: 420 * s),
                              xRadius: 34 * s, yRadius: 34 * s)
    mid.setFill()
    janela.fill()
    lime.withAlphaComponent(0.4).setStroke()
    janela.lineWidth = 8 * s
    janela.stroke()

    // Celular à frente, com a marca da Lifts na tela.
    lime.setFill()
    NSBezierPath(roundedRect: NSRect(x: 560 * s, y: 160 * s, width: 290 * s, height: 560 * s),
                 xRadius: 56 * s, yRadius: 56 * s).fill()
    deep.setFill()
    NSBezierPath(roundedRect: NSRect(x: 582 * s, y: 182 * s, width: 246 * s, height: 516 * s),
                 xRadius: 38 * s, yRadius: 38 * s).fill()
    let larguraMarca = 172 * s, alturaMarca = larguraMarca * marca.size.height / marca.size.width
    marca.draw(in: NSRect(x: (705 - 86) * s, y: 440 * s - alturaMarca / 2, width: larguraMarca, height: alturaMarca))

    // Ondas saindo do celular em direção à janela (o sinal sem fio).
    lime.setStroke()
    for (raio, alfa) in [(60.0, 1.0), (115.0, 0.75), (170.0, 0.5)] {
        let arco = NSBezierPath()
        arco.appendArc(withCenter: NSPoint(x: 520 * s, y: 440 * s), radius: CGFloat(raio) * s, startAngle: 150, endAngle: 210)
        arco.lineWidth = 28 * s
        arco.lineCapStyle = .round
        lime.withAlphaComponent(alfa).setStroke()
        arco.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let pasta = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: pasta)
try! FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! desenhar(base).representation(using: .png, properties: [:])!.write(to: pasta.appendingPathComponent("icon_\(base)x\(base).png"))
    try! desenhar(base * 2).representation(using: .png, properties: [:])!.write(to: pasta.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if CommandLine.arguments.count > 2 {
    try! desenhar(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", pasta.path, "-o", destino]
try! iconutil.run()
iconutil.waitUntilExit()
