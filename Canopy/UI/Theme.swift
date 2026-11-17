import AppKit
import SwiftUI

/// Canopy's visual tokens. Same family as Pitwall: quiet graphite surfaces,
/// hairlines instead of boxes, one accent (a leaf green).
enum Theme {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { ap in ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
    }

    // Surfaces
    static let window = dynamic(light: hex(0xF3F4F6), dark: hex(0x0F1012))
    static let sidebar = dynamic(light: hex(0xECEEF1), dark: hex(0x131417))
    static let panel = dynamic(light: hex(0xFFFFFF), dark: hex(0x17181C))
    static let raised = dynamic(light: hex(0xFFFFFF), dark: hex(0x1D1F24))
    static let field = dynamic(light: hex(0xF6F7F9), dark: hex(0x111215))
    static let hover = dynamic(light: hex(0x000000, 0.04), dark: hex(0xFFFFFF, 0.04))
    static let selection = dynamic(light: hex(0x1F9D55, 0.12), dark: hex(0x3DD68C, 0.13))
    static let hairline = dynamic(light: hex(0x000000, 0.08), dark: hex(0xFFFFFF, 0.07))
    static let strongHairline = dynamic(light: hex(0x000000, 0.14), dark: hex(0xFFFFFF, 0.13))
    static let pill = dynamic(light: hex(0xE9EBEF), dark: hex(0x24262B))

    // Text
    static let text = dynamic(light: hex(0x1B1C1F), dark: hex(0xECEDEF))
    static let text2 = dynamic(light: hex(0x585B63), dark: hex(0xA3A6AE))
    static let text3 = dynamic(light: hex(0x80838B), dark: hex(0x6E727B))

    // Accent + status
    static let accent = dynamic(light: hex(0x1F9D55), dark: hex(0x3DD68C))
    static let accentText = dynamic(light: hex(0x157A41), dark: hex(0x5BE3A1))
    static let amber = dynamic(light: hex(0xB86E00), dark: hex(0xF5A524))
    static let red = dynamic(light: hex(0xC62828), dark: hex(0xFF6B61))
    static let blue = dynamic(light: hex(0x2563EB), dark: hex(0x5B9CFF))
    static let violet = dynamic(light: hex(0x7C4DDB), dark: hex(0xA78BFA))
    static let ai = dynamic(light: hex(0xC2410C), dark: hex(0xFB923C)) // Claude-ish warm orange

    // Syntax
    static let synKey = dynamic(light: hex(0x2B4FB8), dark: hex(0x8AB4FF))
    static let synString = dynamic(light: hex(0x0F7B4A), dark: hex(0x7EE2A8))
    static let synNumber = dynamic(light: hex(0xB4561A), dark: hex(0xF4A261))
    static let synKeyword = dynamic(light: hex(0xA4237B), dark: hex(0xF07BC4))
    static let synType = dynamic(light: hex(0x7C4DDB), dark: hex(0xC4A7FF))
    static let synOperator = dynamic(light: hex(0xB8326B), dark: hex(0xFF8FB1))

    static let connectionColors: [(String, UInt32)] = [
        ("Green", 0x3DD68C), ("Blue", 0x5B9CFF), ("Violet", 0xA78BFA), ("Amber", 0xF5A524), ("Red", 0xFF6B61), ("Gray", 0x8B8F98),
    ]

    static func typeColor(_ v: BValue) -> NSColor {
        switch v {
        case .string: return synString
        case .double, .int32, .int64, .decimal: return synNumber
        case .bool, .null, .undefined: return synKeyword
        case .objectId, .date, .binary, .timestamp, .regex, .javascript, .minKey, .maxKey: return synType
        case .document, .array: return text2
        }
    }

    static func typeColor(name: String) -> Color {
        let c: NSColor
        switch name {
        case "String": c = synString
        case "Double", "Int32", "Int64", "Decimal128": c = synNumber
        case "Boolean": c = synKeyword
        case "Null", "Undefined": c = text3
        case "Object": c = blue
        case "Array": c = violet
        case "Date": c = amber
        default: c = synType
        }
        return Color(nsColor: c)
    }

    static let mono = Font.system(size: 12.5, design: .monospaced)
    static let monoSmall = Font.system(size: 11.5, design: .monospaced)
}

extension Color {
    init(ns: NSColor) { self.init(nsColor: ns) }
    static let cText = Color(nsColor: Theme.text)
    static let cText2 = Color(nsColor: Theme.text2)
    static let cText3 = Color(nsColor: Theme.text3)
    static let cAccent = Color(nsColor: Theme.accent)
    static let cHairline = Color(nsColor: Theme.hairline)
    static let cPanel = Color(nsColor: Theme.panel)
    static let cRaised = Color(nsColor: Theme.raised)
    static let cField = Color(nsColor: Theme.field)
    static let cAI = Color(nsColor: Theme.ai)
    static let cRed = Color(nsColor: Theme.red)
    static let cAmber = Color(nsColor: Theme.amber)
    static let cPill = Color(nsColor: Theme.pill)
}

extension View {
    /// Liquid Glass on macOS 26+, material elsewhere.
    @ViewBuilder
    func canopyGlass(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        }
    }

    func card(_ radius: CGFloat = 10) -> some View {
        self.background(Color.cRaised, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.cHairline))
    }
}

enum Fmt {
    static func bytes(_ b: Double?) -> String {
        guard let b else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }

    static func count(_ n: Int?) -> String {
        guard let n else { return "—" }
        return n.formatted(.number)
    }

    static func compact(_ n: Int?) -> String {
        guard let n else { return "—" }
        return n.formatted(.number.notation(.compactName))
    }

    static func ms(_ t: TimeInterval) -> String {
        t < 1 ? "\(Int((t * 1000).rounded())) ms" : String(format: "%.2f s", t)
    }

    static func duration(_ s: Double) -> String {
        let d = Int(s) / 86400, h = Int(s) % 86400 / 3600, m = Int(s) % 3600 / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
