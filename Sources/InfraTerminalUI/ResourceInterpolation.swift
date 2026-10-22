import SwiftUI

// Use the collection cadence without changing the measurements or scheduling another timer.
enum ResourceInterpolation {
    static func duration(interval: TimeInterval, reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : (interval.isFinite && interval > 0 ? interval : 2) * 0.9
    }
    static func animation(interval: TimeInterval, reduceMotion: Bool) -> Animation? {
        let duration = duration(interval: interval, reduceMotion: reduceMotion)
        return duration > 0 ? .linear(duration: duration) : nil
    }
}

enum ResourceNumberFormat {
    case percentage, megabytesPerSecond
    func text(_ value: Double?) -> String {
        guard let value else { return "—" }
        guard value.isFinite else { return self == .percentage ? "확인 불가" : "—" }
        switch self {
        case .percentage: return value.formatted(.percent.precision(.fractionLength(0)))
        case .megabytesPerSecond: return (value / 1_000_000).formatted(.number.precision(.fractionLength(1)))
        }
    }
}

struct ResourceInterpolatedNumber: View, Animatable {
    var value: Double
    let format: ResourceNumberFormat
    var prefix = ""
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var formattedText: String { prefix + format.text(value) }
    var body: some View { Text(formattedText) }
}
