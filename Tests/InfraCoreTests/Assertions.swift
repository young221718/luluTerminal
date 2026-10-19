import Foundation
import Testing

// Shared helpers retain source locations while keeping fixture assertions compact.
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual == expected, Comment(rawValue: message), sourceLocation: sourceLocation)
}
func expectEqual(_ actual: Double, _ expected: Double, accuracy: Double, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(actual - expected) <= accuracy, sourceLocation: sourceLocation)
}
func expectNotEqual<T: Equatable>(_ actual: T, _ expected: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual != expected, sourceLocation: sourceLocation)
}
func expectTrue(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) { #expect(value, sourceLocation: sourceLocation) }
func expectFalse(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) { #expect(!value, sourceLocation: sourceLocation) }
func expectNil<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) { #expect(value == nil, sourceLocation: sourceLocation) }
func expectNoThrow<T>(_ expression: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation) {
    do { _ = try expression() } catch { Issue.record(error, sourceLocation: sourceLocation) }
}
func expectThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    do { _ = try expression(); Issue.record(Comment(rawValue: "Expected error. " + message), sourceLocation: sourceLocation) } catch {}
}
func expectLessThan(_ actual: Double, _ expected: Double, sourceLocation: SourceLocation = #_sourceLocation) { #expect(actual < expected, sourceLocation: sourceLocation) }
func fail(_ message: String, sourceLocation: SourceLocation = #_sourceLocation) { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
