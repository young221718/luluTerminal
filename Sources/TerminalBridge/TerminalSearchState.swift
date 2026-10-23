import Foundation

public struct TerminalSearchState: Equatable, Sendable {
    public let id: UUID
    public var query: String
    public var total: Int?
    /// Ghostty reports a zero-based match index; nil means it is not known yet.
    public var selected: Int?
}

enum TerminalSearchEvent {
    case started(String?), ended, total(Int?), selected(Int?)
}
