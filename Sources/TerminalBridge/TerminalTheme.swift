import Foundation
import GhosttyTerminal

public struct TerminalPalette: Equatable, Codable {
    public var background: UInt32
    public var foreground: UInt32
    public var accent: UInt32

    public init(background: UInt32, foreground: UInt32, accent: UInt32) {
        self.background = background
        self.foreground = foreground
        self.accent = accent
    }

    public static let light = TerminalPalette(background: 0xFFFFFF, foreground: 0x242A30, accent: 0x176E69)
    public static let dark = TerminalPalette(background: 0x181B20, foreground: 0xE4E9ED, accent: 0x79CCC1)
}

public struct TerminalStyle: Equatable {
    public var light: TerminalPalette
    public var dark: TerminalPalette
    public var fontFamily: String
    public var fontSize: Double

    public init(light: TerminalPalette = .light, dark: TerminalPalette = .dark,
                fontFamily: String = "Menlo", fontSize: Double = 14) {
        self.light = light
        self.dark = dark
        self.fontFamily = fontFamily
        self.fontSize = fontSize
    }

    public static let `default` = TerminalStyle()

    var configuration: TerminalConfiguration {
        .init {
            $0.withFontFamily(fontFamily)
            $0.withFontSize(Float(fontSize))
        }
    }

    var theme: TerminalTheme {
        TerminalTheme(light: colors(light, dark: false), dark: colors(dark, dark: true))
    }

    private func colors(_ palette: TerminalPalette, dark: Bool) -> TerminalConfiguration {
        let ansi: [UInt32] = dark
            ? [0x2B2D30, 0xD3867B, 0xA2B58D, 0xD8BC80, 0x91AFC6, 0xB69BBE, 0x8DB8B0, 0xDDD9D1,
               0x777971, 0xE7A194, 0xBDCCA9, 0xE8CF9C, 0xAFC7DA, 0xCDB4D1, 0xACCEC5, 0xF5F2EB]
            : [0x302F2A, 0xA6413C, 0x4F6B4F, 0x8E6C2C, 0x466C8E, 0x86607D, 0x467A78, 0xD9D5CD,
               0x827E75, 0xBB5146, 0x5A7A56, 0xA27B32, 0x557FA7, 0x986D8F, 0x518C88, 0xFBFAF7]
        return .init {
            // Preserve ANSI backgrounds while keeping faint foregrounds readable in both modes.
            $0.withMinimumContrast(4.5)
            $0.withBackground(hex(palette.background))
            $0.withForeground(hex(palette.foreground))
            $0.withCursorColor(hex(palette.accent))
            $0.withCursorText(hex(palette.background))
            $0.withSelectionBackground(hex(selectionBackground(palette, amount: dark ? 0.26 : 0.18)))
            $0.withSelectionForeground(hex(palette.foreground))
            for (index, color) in ansi.enumerated() {
                $0.withPalette(index, color: "#" + hex(color))
            }
        }
    }

    private func hex(_ value: UInt32) -> String { String(format: "%06X", value & 0xFFFFFF) }

    private func selectionBackground(_ palette: TerminalPalette, amount: Double) -> UInt32 {
        [16, 8, 0].reduce(UInt32(0)) { result, shift in
            let base = Double((palette.background >> shift) & 0xFF)
            let accent = Double((palette.accent >> shift) & 0xFF)
            return result | (UInt32((base + (accent - base) * amount).rounded()) << shift)
        }
    }
}
