// 生成 1024×1024 的应用图标 PNG：深色底 + 三层叠放的卡片（多开）+ 一个绿色在线点（保活）。
// 用法：swift scripts/make-icon.swift <输出.png>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS 图标网格：内容区 824，圆角约 185
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let platePath = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(white: 0.20, alpha: 1), NSColor(white: 0.05, alpha: 1)])!
    .draw(in: platePath, angle: -90)
NSColor(white: 1, alpha: 0.08).setStroke()
platePath.lineWidth = 4
platePath.stroke()

// 三张错开的卡片，越靠前越亮
for (i, alpha) in [0.28, 0.55, 1.0].enumerated() {
    let offset = Double(i) * 70
    let card = NSRect(x: 250 + offset, y: 520 - offset, width: 380, height: 260)
    let path = NSBezierPath(roundedRect: card, xRadius: 48, yRadius: 48)
    NSColor(white: 1, alpha: alpha).setFill()
    path.fill()
    if i < 2 {
        NSColor(white: 0.08, alpha: 0.9).setStroke()
        path.lineWidth = 10
        path.stroke()
    }
}

// 最前面那张卡片上的「终端提示符」
let prompt = NSBezierPath()
prompt.move(to: NSPoint(x: 445, y: 545))
prompt.line(to: NSPoint(x: 505, y: 500))
prompt.line(to: NSPoint(x: 445, y: 455))
prompt.lineWidth = 30
prompt.lineCapStyle = .round
prompt.lineJoinStyle = .round
NSColor(white: 0.08, alpha: 1).setStroke()
prompt.stroke()
let cursor = NSBezierPath(roundedRect: NSRect(x: 535, y: 440, width: 100, height: 28), xRadius: 14, yRadius: 14)
NSColor(white: 0.08, alpha: 1).setFill()
cursor.fill()

// 在线指示点
let dot = NSRect(x: 690, y: 250, width: 120, height: 120)
NSColor(white: 0.05, alpha: 1).setFill()
NSBezierPath(ovalIn: dot.insetBy(dx: -18, dy: -18)).fill()
NSColor(calibratedRed: 0.20, green: 0.84, blue: 0.42, alpha: 1).setFill()
NSBezierPath(ovalIn: dot).fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("渲染图标失败")
}
try png.write(to: output)
