#!/usr/bin/env swift
import AppKit
import Foundation

let canvasWidth: CGFloat = 442
let canvasHeight: CGFloat = 961
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "media/screenshots")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let background = color(0xFBFAF5)
let panel = color(0xFFFDF7)
let ink = color(0x132421)
let muted = color(0x7C827E)
let line = color(0xDFE3DD)
let accent = color(0x0B6B61)
let accentSoft = color(0xD8EEE7)
let warm = color(0xB86A35)
let warmSoft = color(0xF2E3D4)
let danger = color(0xB76E69)
let dangerSoft = color(0xF1DDDA)
let blueSoft = color(0xE5EDF5)
let cardShadow = NSColor.black.withAlphaComponent(0.08)

struct Screen {
    let name: String
    let title: String
    let subtitle: String
    let draw: () -> Void
}

func color(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
    NSRect(x: x, y: canvasHeight - y - height, width: width, height: height)
}

func fillRounded(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil, lineWidth: CGFloat = 1) {
    let path = NSBezierPath(roundedRect: rect(x, y, width, height), xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }
}

func drawText(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = ink, align: NSTextAlignment = .left) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = align
    paragraph.lineBreakMode = .byTruncatingTail
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    (text as NSString).draw(in: rect(x, y, width, height), withAttributes: attributes)
}

func drawMultiline(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = ink, align: NSTextAlignment = .left) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = align
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineSpacing = 3
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    (text as NSString).draw(in: rect(x, y, width, height), withAttributes: attributes)
}

func drawPill(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, color fill: NSColor = accentSoft, textColor: NSColor = accent) {
    fillRounded(x, y, width, 32, radius: 16, fill: fill, stroke: line)
    drawText(text, x + 12, y + 7, width - 24, 18, size: 13, weight: .semibold, color: textColor, align: .center)
}

func drawCard(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, fill: NSColor = panel) {
    NSGraphicsContext.current?.cgContext.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: cardShadow.cgColor)
    fillRounded(x, y, width, height, radius: 14, fill: fill, stroke: line)
    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
}

func drawHeader(status: String = "Connected") {
    drawText("9:41", 32, 24, 74, 24, size: 19, weight: .bold)
    drawText("LTE 100", 330, 27, 80, 20, size: 12, weight: .bold, color: muted, align: .right)
    drawText("maludex", 0, 82, canvasWidth, 38, size: 30, weight: .bold, align: .center)
    fillRounded(280, 78, 138, 44, radius: 22, fill: panel, stroke: line)
    fillRounded(297, 94, 10, 10, radius: 5, fill: accent)
    drawText(status, 314, 88, 88, 22, size: 14, weight: .semibold)
}

func drawAppTile(_ y: CGFloat, subtitle: String) {
    drawCard(18, y, 406, 92)
    fillRounded(36, y + 20, 52, 52, radius: 13, fill: color(0x203A55))
    fillRounded(61, y + 45, 27, 27, radius: 10, fill: warm.withAlphaComponent(0.85))
    drawText(">_", 47, y + 35, 32, 20, size: 17, weight: .bold, color: NSColor.white, align: .center)
    drawText("maludex", 104, y + 20, 190, 34, size: 27, weight: .bold)
    drawText(subtitle, 106, y + 55, 210, 24, size: 15, weight: .semibold, color: muted)
}

func drawBottomComposer() {
    fillRounded(0, 790, canvasWidth, 171, radius: 0, fill: panel, stroke: line)
    fillRounded(24, 815, 394, 70, radius: 12, fill: background, stroke: line)
    drawText("Ask maludex...", 42, 836, 210, 28, size: 19, color: muted)
    let buttons: [(CGFloat, String)] = [(30, "stop"), (106, "photo"), (182, "file"), (258, "mic")]
    for (x, label) in buttons {
        fillRounded(x, 904, 52, 52, radius: 26, fill: accentSoft)
        drawText(label, x, 921, 52, 18, size: 11, weight: .bold, color: accent, align: .center)
    }
    fillRounded(336, 902, 78, 54, radius: 27, fill: accent)
    drawText("send", 336, 920, 78, 18, size: 13, weight: .bold, color: NSColor.white, align: .center)
}

func drawQRCode(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat) {
    fillRounded(x, y, size, size, radius: 8, fill: NSColor.white, stroke: line)
    let cells = 21
    let cell = (size - 24) / CGFloat(cells)
    let originX = x + 12
    let originY = y + 12
    func square(_ col: Int, _ row: Int, _ fill: NSColor = ink) {
        fillRounded(originX + CGFloat(col) * cell, originY + CGFloat(row) * cell, cell * 0.92, cell * 0.92, radius: 1, fill: fill)
    }
    func finder(_ col: Int, _ row: Int) {
        for r in 0..<7 {
            for c in 0..<7 {
                if r == 0 || r == 6 || c == 0 || c == 6 || (r >= 2 && r <= 4 && c >= 2 && c <= 4) {
                    square(col + c, row + r)
                }
            }
        }
    }
    finder(0, 0)
    finder(14, 0)
    finder(0, 14)
    for row in 0..<cells {
        for col in 0..<cells {
            let inFinder = (col < 8 && row < 8) || (col > 12 && row < 8) || (col < 8 && row > 12)
            if !inFinder && ((col * 17 + row * 31 + col * row) % 5 == 0 || (col + row) % 7 == 0) {
                square(col, row)
            }
        }
    }
}

func drawSearchBubble(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, highlighted: Bool) {
    drawCard(x, y, width, highlighted ? 138 : 106, fill: highlighted ? color(0xFFF8E8) : panel)
    drawText("maludex", x + 16, y + 14, 110, 20, size: 14, weight: .bold, color: highlighted ? warm : ink)
    drawMultiline("Found the Control Center repair fix. Long search hits now expand and highlight when opened.", x + 16, y + 42, width - 32, 64, size: 15)
    if highlighted {
        drawPill("Search result", x + 16, y + 102, 126, color: warmSoft, textColor: warm)
    }
}

func baseScreen() {
    background.setFill()
    NSBezierPath(rect: rect(0, 0, canvasWidth, canvasHeight)).fill()
    drawHeader()
}

let screens: [Screen] = [
    Screen(name: "pairing", title: "Pair safely", subtitle: "QR capability token, never public app-server", draw: {
        baseScreen()
        drawAppTile(146, subtitle: "v0.7.2 local-first bridge")
        drawText("Pair bridge", 28, 266, 260, 32, size: 25, weight: .bold)
        drawMultiline("Scan the private QR from your Mac. Tokens stay in Keychain and the bridge stays off the public internet.", 28, 304, 388, 58, size: 15, color: muted)
        drawQRCode(88, 382, 266)
        drawPill("Bearer token is hidden", 111, 676, 220, color: warmSoft, textColor: warm)
    }),
    Screen(name: "connected-home", title: "Connected dashboard", subtitle: "Bridge, app, queue, and handoff status", draw: {
        baseScreen()
        drawAppTile(146, subtitle: "Studio Mac - 100.75.40.51")
        drawText("Workspace", 28, 270, 240, 30, size: 25, weight: .bold)
        drawCard(28, 318, 386, 116)
        drawText("Bridge", 50, 340, 120, 18, size: 13, weight: .bold, color: muted)
        drawText("0.7.2 / 0.7.2", 50, 365, 190, 30, size: 25, weight: .bold)
        drawPill("Healthy", 284, 356, 92)
        drawCard(28, 456, 386, 126)
        drawText("Mobile handoff", 50, 478, 190, 20, size: 15, weight: .bold)
        drawMultiline("Recent iPhone prompts are retained privately on the Mac for desktop recovery.", 50, 506, 314, 48, size: 15, color: muted)
        drawPill("200 retained", 50, 548, 118, color: blueSoft, textColor: color(0x416A8A))
        drawBottomComposer()
    }),
    Screen(name: "session-controls", title: "Tune Codex from iPhone", subtitle: "Model, intelligence, approvals, and projects", draw: {
        baseScreen()
        drawText("Session", 28, 146, 220, 32, size: 26, weight: .bold)
        let rows: [(String, String, NSColor)] = [
            ("Project", "~/Documents/maludex", accentSoft),
            ("Model", "GPT-5.5", blueSoft),
            ("Intelligence", "High", warmSoft),
            ("Permissions", "Workspace write", accentSoft),
            ("Approvals", "On request", warmSoft),
            ("Auto compact", "Enabled", accentSoft)
        ]
        for (index, row) in rows.enumerated() {
            let y = CGFloat(200 + index * 82)
            drawCard(28, y, 386, 62)
            drawText(row.0, 50, y + 15, 132, 19, size: 14, weight: .bold, color: muted)
            drawText(row.1, 186, y + 14, 174, 22, size: 17, weight: .semibold)
            fillRounded(374, y + 20, 18, 18, radius: 9, fill: row.2)
        }
    }),
    Screen(name: "streaming-turn", title: "Searchable transcript", subtitle: "Streaming, copied text, attachments, and jump-to-result", draw: {
        baseScreen()
        drawText("Conversation", 28, 146, 220, 32, size: 26, weight: .bold)
        fillRounded(28, 192, 386, 48, radius: 14, fill: NSColor.white, stroke: line)
        drawText("Search: repair", 48, 206, 230, 20, size: 16, weight: .semibold, color: muted)
        drawPill("2 matches", 300, 200, 94, color: accentSoft, textColor: accent)
        drawSearchBubble(28, 266, 386, highlighted: true)
        drawCard(28, 426, 386, 150)
        drawText("You", 50, 448, 80, 18, size: 14, weight: .bold, color: accent)
        drawMultiline("Update the GitHub README and regenerate the latest demo video.", 50, 476, 314, 50, size: 17)
        drawPill("image + file attached", 50, 532, 160, color: blueSoft, textColor: color(0x416A8A))
        drawCard(28, 598, 386, 108)
        drawText("Queued prompts", 50, 620, 160, 20, size: 15, weight: .bold)
        drawMultiline("Drag to reorder, steer the active turn, or stop safely.", 50, 648, 300, 40, size: 15, color: muted)
        drawBottomComposer()
    }),
    Screen(name: "approval-card", title: "Approve on request", subtitle: "Mobile approvals without full access defaults", draw: {
        baseScreen()
        drawText("Approval", 28, 146, 200, 32, size: 26, weight: .bold)
        drawCard(28, 204, 386, 310, fill: color(0xFFF8EA))
        drawText("Command approval", 52, 230, 220, 24, size: 20, weight: .bold)
        drawPill("Waiting", 300, 226, 86, color: warmSoft, textColor: warm)
        drawText("cwd", 52, 282, 60, 18, size: 13, weight: .bold, color: muted)
        drawText("~/Documents/maludex", 112, 282, 230, 18, size: 13, color: muted)
        fillRounded(52, 320, 304, 72, radius: 8, fill: color(0xF8F5EC), stroke: line)
        drawMultiline("git status --short\nnpm test -- --run bridge/test/process-error.test.ts", 66, 334, 276, 48, size: 13, color: ink)
        fillRounded(52, 430, 140, 52, radius: 14, fill: dangerSoft, stroke: line)
        drawText("Deny", 52, 446, 140, 20, size: 17, weight: .bold, color: danger, align: .center)
        fillRounded(216, 430, 140, 52, radius: 14, fill: accent)
        drawText("Approve", 216, 446, 140, 20, size: 17, weight: .bold, color: NSColor.white, align: .center)
        drawCard(28, 552, 386, 96)
        drawText("Security default", 50, 574, 180, 20, size: 15, weight: .bold)
        drawMultiline("No danger-full-access and no never-approve from mobile.", 50, 602, 300, 36, size: 15, color: muted)
    }),
    Screen(name: "bridge-switcher", title: "Switch Macs", subtitle: "Multiple bridges plus repaired Control Center", draw: {
        baseScreen()
        drawText("Bridges", 28, 146, 200, 32, size: 26, weight: .bold)
        let bridges = [
            ("Studio Mac", "100.75.40.51 - 0.7.2", "Live"),
            ("MacBook Air", "100.83.10.24 - saved", "Ready"),
            ("Office Mac", "wss://maludex.example.com", "TLS")
        ]
        for (index, bridge) in bridges.enumerated() {
            let y = CGFloat(198 + index * 102)
            drawCard(28, y, 386, 78, fill: index == 0 ? color(0xF2FBF7) : panel)
            drawText(bridge.0, 54, y + 16, 190, 24, size: 19, weight: .bold)
            drawText(bridge.1, 54, y + 45, 230, 18, size: 13, color: muted)
            drawPill(bridge.2, 300, y + 22, 88, color: index == 0 ? accentSoft : blueSoft, textColor: index == 0 ? accent : color(0x416A8A))
        }
        drawCard(28, 536, 386, 156, fill: color(0xF7F5EE))
        drawText("Control Center", 54, 560, 180, 24, size: 20, weight: .bold)
        drawText("Repair path", 54, 594, 120, 18, size: 13, weight: .bold, color: muted)
        drawText("Healthy", 180, 594, 110, 18, size: 15, weight: .semibold, color: accent)
        drawText("Version", 54, 626, 120, 18, size: 13, weight: .bold, color: muted)
        drawText("0.7.2 / 0.7.2", 180, 626, 150, 18, size: 15, weight: .semibold)
        drawPill("Repair can find npm", 54, 658, 156, color: warmSoft, textColor: warm)
    })
]

for screen in screens {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvasWidth),
        pixelsHigh: Int(canvasHeight),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    screen.draw()
    NSGraphicsContext.restoreGraphicsState()

    let url = outputDirectory.appendingPathComponent("\(screen.name).png")
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(screen.name).png")
    }
    try data.write(to: url)
    print(url.path)
}
