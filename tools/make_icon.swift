import AppKit
// Genera AppIcon.icns: cuadrado redondeado naranja con una bocina blanca.
func render(_ px: Int) -> Data {
    let img = NSImage(size: NSSize(width: px, height: px), flipped: false) { r in
        let s = CGFloat(px)
        let inset = s * 0.06
        let rect = r.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.225, yRadius: s * 0.225)
        NSGradient(starting: NSColor(red: 1.00, green: 0.62, blue: 0.20, alpha: 1),
                   ending: NSColor(red: 0.95, green: 0.38, blue: 0.05, alpha: 1))!.draw(in: path, angle: -90)
        let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let sym = NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let w = sym.size.width, h = sym.size.height
            sym.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
        }
        return true
    }
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}
let dir = CommandLine.arguments[1] + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (n, px) in [("16",16),("16@2x",32),("32",32),("32@2x",64),("128",128),("128@2x",256),("256",256),("256@2x",512),("512",512),("512@2x",1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(n.replacingOccurrences(of: "@2x", with: ""))\(n.contains("@2x") ? "@2x" : "").png".replacingOccurrences(of: "icon_\(n.replacingOccurrences(of: "@2x", with: ""))", with: "icon_\(n.replacingOccurrences(of: "@2x", with: ""))x\(n.replacingOccurrences(of: "@2x", with: ""))")))
}
