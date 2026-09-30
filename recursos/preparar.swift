import AppKit

// Gera recursos/logo-horizontal.png (logo branca da Lifts, sem margem) e recursos/marca.png (só o V lime)
// a partir do original em ~/planos_lifts/assets. Rode: swift recursos/preparar.swift
let origem = NSString(string: "~/planos_lifts/assets/horizontal-branco.png").expandingTildeInPath
let pasta = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

guard let fonte = CGImageSourceCreateWithURL(URL(fileURLWithPath: origem) as CFURL, nil),
      let imagem = CGImageSourceCreateImageAtIndex(fonte, 0, nil) else { fatalError("sem logo") }

let largura = imagem.width, altura = imagem.height
var pixels = [UInt8](repeating: 0, count: largura * altura * 4)
let ctx = CGContext(data: &pixels, width: largura, height: altura, bitsPerComponent: 8, bytesPerRow: largura * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(imagem, in: CGRect(x: 0, y: 0, width: largura, height: altura))

func caixa(_ vale: (UInt8, UInt8, UInt8, UInt8) -> Bool) -> CGRect {
    var x0 = largura, y0 = altura, x1 = 0, y1 = 0
    for y in 0..<altura {
        for x in 0..<largura {
            let i = (y * largura + x) * 4
            if vale(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]) {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
    }
    return CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
}

func salvar(_ recorte: CGRect, larguraFinal: Int, nome: String) {
    let cortada = imagem.cropping(to: recorte)!
    let alturaFinal = Int((Double(larguraFinal) * recorte.height / recorte.width).rounded())
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: larguraFinal, pixelsHigh: alturaFinal, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(cgImage: cortada, size: .zero).draw(in: NSRect(x: 0, y: 0, width: larguraFinal, height: alturaFinal))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: pasta.appendingPathComponent(nome))
}

salvar(caixa { _, _, _, a in a > 16 }, larguraFinal: 560, nome: "logo-horizontal.png")
salvar(caixa { r, g, b, a in a > 200 && r > 150 && g > 150 && b < 130 }, larguraFinal: 420, nome: "marca.png")
