import Foundation
import Testing
@testable import InfraTerminalUI

@MainActor struct AppearancePreferencesTests {
    @Test func absentOrUnknownPreferenceUsesLight() throws {
        let name = "AppearanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppearancePreferences(defaults: defaults).selection == .light)
        defaults.set("unknown", forKey: "appearance")
        #expect(AppearancePreferences(defaults: defaults).selection == .light)
    }

    @Test func selectionSurvivesReloadWithoutChangingOtherPreferences() throws {
        let name = "AppearanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("preserved", forKey: "unrelated")
        let preferences = AppearancePreferences(defaults: defaults)
        preferences.selection = .dark
        #expect(AppearancePreferences(defaults: defaults).selection == .dark)
        preferences.selection = .light
        #expect(AppearancePreferences(defaults: defaults).selection == .light)
        #expect(defaults.string(forKey: "unrelated") == "preserved")
    }
}

@MainActor struct CustomAppearancePreferencesTests {
    @Test func palettesAndFontPersistIndependently() throws {
        let name = "AppearanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("preserved", forKey: "unrelated")
        let preferences = AppearancePreferences(defaults: defaults)
        var light = preferences.lightPalette
        light.background = 0xF0EAE2
        light.foreground = 0x302A24
        light.accent = 0x9A5738
        preferences.setPalette(light, for: .light)
        preferences.setFont(family: "Menlo", size: 19)
        preferences.selection = .dark
        let loaded = AppearancePreferences(defaults: defaults)
        #expect(loaded.lightPalette == light)
        #expect(loaded.terminalStyle.light == light)
        #expect(loaded.terminalStyle.fontSize == 19)
        #expect(loaded.darkPalette.background == 0x181B20)
        #expect(loaded.fontFamily == "Menlo")
        #expect(loaded.fontSize == 19)
        #expect(loaded.selection == .dark)
        #expect(defaults.string(forKey: "unrelated") == "preserved")
    }

    @Test func invalidPersistedFieldsFallBackWithoutDiscardingValidColors() throws {
        let name = "AppearanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(-1, forKey: "appearance.light.background")
        defaults.set(0xFF000000, forKey: "appearance.light.foreground")
        defaults.set(0x9A5738, forKey: "appearance.light.accent")
        defaults.set("Missing Test Font", forKey: "terminal.fontFamily")
        defaults.set(Double.nan, forKey: "terminal.fontSize")
        let loaded = AppearancePreferences(defaults: defaults)
        #expect(loaded.lightPalette.background == 0xFFFFFF)
        #expect(loaded.lightPalette.foreground == 0x242A30)
        #expect(loaded.lightPalette.accent == 0x9A5738)
        #expect(loaded.fontFamily == "Menlo")
        #expect(loaded.fontSize == 14)
        loaded.setFont(family: "Menlo", size: 29)
        #expect(loaded.fontSize == 14)
        loaded.setFont(family: "Menlo", size: 10)
        #expect(loaded.fontSize == 10)
        loaded.setFont(family: "Menlo", size: 28)
        #expect(loaded.fontSize == 28)
    }


    @Test func invalidInputsNormalizeBeforeSavingAndColorsFollowSelectedMode() throws {
        let name = "AppearanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AppearancePreferences(defaults: defaults)
        var light = preferences.lightPalette
        light.background = .max
        light.accent = 0x885533
        preferences.setPalette(light, for: .light)
        #expect(preferences.lightPalette.background == 0xFFFFFF)
        #expect(preferences.colors.accent.rgbValue == 0x885533)
        let healthy = preferences.colors.healthy.rgbValue
        light.accent = 0x8855AA
        preferences.setPalette(light, for: .light)
        #expect(preferences.colors.healthy.rgbValue == healthy)
        preferences.selection = .dark
        #expect(preferences.colors.background.rgbValue == 0x181B20)
        preferences.setFont(family: "Missing Test Font", size: .infinity)
        let loaded = AppearancePreferences(defaults: defaults)
        #expect(loaded.lightPalette.background == 0xFFFFFF)
        #expect(loaded.lightPalette.accent == 0x8855AA)
        #expect(loaded.fontFamily == "Menlo")
        #expect(loaded.fontSize == 14)
    }

    @Test func resettingOneModeAndFontPreservesOtherPreferences() throws {
        let name = "AppearanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("preserved", forKey: "unrelated")
        let preferences = AppearancePreferences(defaults: defaults)
        var light = preferences.lightPalette, dark = preferences.darkPalette
        light.background = 0xEEE8E0
        dark.background = 0x242424
        preferences.setPalette(light, for: .light)
        preferences.setPalette(dark, for: .dark)
        preferences.setFont(family: "Menlo", size: 18)
        preferences.selection = .dark
        preferences.resetPalette(for: .light)
        #expect(preferences.lightPalette.background == 0xFFFFFF)
        #expect(preferences.darkPalette == dark)
        #expect(preferences.fontSize == 18)
        preferences.resetFont()
        let loaded = AppearancePreferences(defaults: defaults)
        #expect(loaded.darkPalette == dark)
        #expect(loaded.fontSize == 14)
        #expect(loaded.fontFamily == "Menlo")
        #expect(loaded.selection == .dark)
        #expect(defaults.string(forKey: "unrelated") == "preserved")
    }
}
