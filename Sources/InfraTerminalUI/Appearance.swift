import AppKit
import CoreFoundation
import SwiftUI
import TerminalBridge

public enum AppAppearance: String, CaseIterable, Identifiable {
    case light, dark
    public var id: String { rawValue }
    public var title: String { self == .light ? "라이트" : "다크" }
    public var colorScheme: ColorScheme { self == .light ? .light : .dark }
}

@MainActor public final class AppearancePreferences: ObservableObject {
    private let defaults: UserDefaults
    public let availableFontFamilies: [String]
    @Published public var selection: AppAppearance {
        didSet { defaults.set(selection.rawValue, forKey: "appearance") }
    }
    @Published public private(set) var lightPalette: TerminalPalette
    @Published public private(set) var darkPalette: TerminalPalette
    @Published public private(set) var fontFamily: String
    @Published public private(set) var fontSize: Double

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        availableFontFamilies = Self.monospacedFontFamilies()
        selection = defaults.string(forKey: "appearance").flatMap(AppAppearance.init(rawValue:)) ?? .light
        lightPalette = Self.loadPalette(for: .light, defaults: defaults)
        darkPalette = Self.loadPalette(for: .dark, defaults: defaults)
        let storedFont = defaults.string(forKey: "terminal.fontFamily") ?? "Menlo"
        fontFamily = availableFontFamilies.contains(storedFont) ? storedFont : "Menlo"
        fontSize = Self.validFontSize((defaults.object(forKey: "terminal.fontSize") as? NSNumber)?.doubleValue ?? 14)
    }

    public var terminalStyle: TerminalStyle {
        TerminalStyle(light: lightPalette, dark: darkPalette, fontFamily: fontFamily, fontSize: fontSize)
    }
    public var colors: AppearanceColors { AppearanceColors(palette: palette(for: selection), dark: selection == .dark) }
    public func palette(for mode: AppAppearance) -> TerminalPalette { mode == .light ? lightPalette : darkPalette }

    public func setPalette(_ value: TerminalPalette, for mode: AppAppearance) {
        let fallback: TerminalPalette = mode == .light ? .light : .dark
        let palette = TerminalPalette(background: value.background <= 0xFFFFFF ? value.background : fallback.background,
                                      foreground: value.foreground <= 0xFFFFFF ? value.foreground : fallback.foreground,
                                      accent: value.accent <= 0xFFFFFF ? value.accent : fallback.accent)
        if mode == .light { lightPalette = palette } else { darkPalette = palette }
        let prefix = "appearance.\(mode.rawValue)."
        defaults.set(Int(palette.background), forKey: prefix + "background")
        defaults.set(Int(palette.foreground), forKey: prefix + "foreground")
        defaults.set(Int(palette.accent), forKey: prefix + "accent")
    }

    public func setFont(family: String, size: Double) {
        fontFamily = availableFontFamilies.contains(family) ? family : "Menlo"
        fontSize = Self.validFontSize(size)
        defaults.set(fontFamily, forKey: "terminal.fontFamily")
        defaults.set(fontSize, forKey: "terminal.fontSize")
    }
    public func resetPalette(for mode: AppAppearance) { setPalette(mode == .light ? .light : .dark, for: mode) }
    public func resetFont() { setFont(family: "Menlo", size: 14) }

    private static func validFontSize(_ value: Double) -> Double {
        value.isFinite && (10...28).contains(value) ? value : 14
    }
    private static func monospacedFontFamilies() -> [String] {
        let manager = NSFontManager.shared
        let families = manager.availableFontFamilies.filter { family in
            manager.font(withFamily: family, traits: [], weight: 5, size: 14)?.isFixedPitch == true
        }
        return Array(Set(families + ["Menlo"])).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private static func loadPalette(for mode: AppAppearance, defaults: UserDefaults) -> TerminalPalette {
        let fallback: TerminalPalette = mode == .light ? .light : .dark
        func rgb(_ key: String, fallback: UInt32) -> UInt32 {
            guard let number = defaults.object(forKey: "appearance.\(mode.rawValue)." + key) as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return fallback }
            let value = number.doubleValue
            guard value.isFinite, value >= 0, value <= 0xFFFFFF, value.rounded() == value else { return fallback }
            return UInt32(value)
        }
        return TerminalPalette(background: rgb("background", fallback: fallback.background),
                               foreground: rgb("foreground", fallback: fallback.foreground),
                               accent: rgb("accent", fallback: fallback.accent))
    }
}

public struct AppearanceColors {
    let palette: TerminalPalette
    let dark: Bool
    public var background: Color { Color(rgb: palette.background) }
    public var panel: Color { Color(rgb: blend(palette.background, dark ? palette.foreground : 0xFFFFFF, amount: dark ? 0.025 : 0.55)) }
    public var sidebar: Color { Color(rgb: blend(palette.background, palette.foreground, amount: dark ? 0.04 : 0.035)) }
    public var accent: Color { Color(rgb: palette.accent) }
    public var text: Color { Color(rgb: palette.foreground) }
    public var muted: Color { Color(rgb: blend(palette.foreground, palette.background, amount: 0.36)) }
    public var track: Color { Color(rgb: blend(palette.background, palette.foreground, amount: 0.13)) }
    public var healthy: Color { Color(rgb: dark ? 0x96AD96 : 0x69866D) }

    private func blend(_ from: UInt32, _ to: UInt32, amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            UInt32((Double((from >> shift) & 255) * (1 - amount) + Double((to >> shift) & 255) * amount).rounded())
        }
        return channel(16) << 16 | channel(8) << 8 | channel(0)
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                  green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
    }
    var rgbValue: UInt32? {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
        return channel(color.redComponent) << 16 | channel(color.greenComponent) << 8 | channel(color.blueComponent)
    }
}
