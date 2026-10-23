import Foundation
import SwiftUI

@MainActor public final class ConnectionPreferences: ObservableObject {
    private let defaults: UserDefaults
    @Published public var automaticallyReconnect: Bool {
        didSet { defaults.set(automaticallyReconnect, forKey: "connection.automaticallyReconnect") }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticallyReconnect = defaults.bool(forKey: "connection.automaticallyReconnect")
    }
}
