import Foundation
import Testing
@testable import InfraTerminalUI

@MainActor struct ResourceInterpolationTests {
    @Test func transitionUsesMostOfThePollingIntervalAndHonorsReducedMotion() {
        #expect(ResourceInterpolation.duration(interval: 2, reduceMotion: false) == 1.8)
        #expect(ResourceInterpolation.duration(interval: 5, reduceMotion: false) == 4.5)
        #expect(ResourceInterpolation.duration(interval: 10, reduceMotion: false) == 9)
        #expect(ResourceInterpolation.duration(interval: .nan, reduceMotion: false) == 1.8)
        #expect(ResourceInterpolation.duration(interval: 0, reduceMotion: false) == 1.8)
        #expect(ResourceInterpolation.duration(interval: 2, reduceMotion: true) == 0)
    }

    @Test func percentageAndNetworkRenderTheInterpolatedMidpoint() {
        var percentage = ResourceInterpolatedNumber(value: 0.8, format: .percentage)
        percentage.animatableData = 0.5
        #expect(percentage.formattedText == InfraTerminalUI.percentage(0.5))
        #expect(percentage.value == 0.5)
        var network = ResourceInterpolatedNumber(value: 3_000_000, format: .megabytesPerSecond, prefix: "↓ ")
        network.animatableData = 2_000_000
        #expect(network.formattedText == "↓ " + 2.0.formatted(.number.precision(.fractionLength(1))))
    }

    @Test func missingAndNonfiniteMeasurementsNeverBecomeAnInterpolatedZero() {
        #expect(ResourceNumberFormat.percentage.text(nil) == "—")
        #expect(ResourceNumberFormat.percentage.text(.nan) == "확인 불가")
        #expect(ResourceNumberFormat.megabytesPerSecond.text(.infinity) == "—")
        #expect(ResourceNumberFormat.percentage.text(0) == percentage(0))
    }
}
