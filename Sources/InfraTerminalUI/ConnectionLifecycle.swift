import AppKit
import Network
import SwiftUI

/// Coalesces system events; AppModel owns which existing sessions may reconnect.
@MainActor final class ConnectionLifecycle: ObservableObject {
    var onInterrupted: (() -> Void)?
    var onRestored: (() -> Void)?
    private let center: NotificationCenter
    private let observeNetwork: Bool
    private let delay: Duration
    private var observers: [NSObjectProtocol] = []
    private var monitor: NWPathMonitor?
    private var pending: Task<Void, Never>?
    private var generation = UUID()
    private var running = false
    private var sleeping = false
    private var available: Bool?
    private var signature: String?

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         observeNetwork: Bool = true, delay: Duration = .milliseconds(750)) {
        self.center = center
        self.observeNetwork = observeNetwork
        self.delay = delay
    }

    func start() {
        guard !running else { return }
        running = true
        let token = generation
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard self?.generation == token else { return }
                    self?.receiveSleep()
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard self?.generation == token else { return }
                    self?.receiveWake()
                }
            }
        ]
        guard observeNetwork else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let interfaces = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
                .map { "\($0.type):\($0.index)" }.sorted().joined(separator: ",")
            let signature = interfaces + "|" + path.gateways.map { String(describing: $0) }.sorted().joined(separator: ",")
            Task { @MainActor [weak self] in
                guard self?.generation == token else { return }
                self?.receivePath(available: available, signature: signature)
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.chanyoung.infra-terminal.connection-path"))
    }

    func stop() {
        running = false
        generation = UUID()
        pending?.cancel()
        pending = nil
        observers.forEach(center.removeObserver)
        observers = []
        monitor?.cancel()
        monitor = nil
        available = nil
        signature = nil
        sleeping = false
    }

    func receiveSleep() {
        guard running, !sleeping else { return }
        sleeping = true
        interrupt()
    }

    func receiveWake() {
        guard running, sleeping else { return }
        sleeping = false
        if available != false { restore() }
    }

    func receivePath(available next: Bool, signature nextSignature: String) {
        guard running else { return }
        let previous = available
        let changed = signature != nil && signature != nextSignature
        available = next
        signature = nextSignature
        guard let previous else {
            if !next { interrupt() }
            return
        }
        if !next {
            if previous { interrupt() }
        } else if !previous || changed {
            if previous { interrupt() }
            if !sleeping { restore() }
        }
    }

    private func interrupt() {
        pending?.cancel()
        pending = nil
        onInterrupted?()
    }

    private func restore() {
        pending?.cancel()
        let token = generation
        let delay = delay
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.running, self.generation == token,
                  !self.sleeping, self.available != false else { return }
            self.pending = nil
            self.onRestored?()
        }
    }

    deinit {
        pending?.cancel()
        monitor?.cancel()
        observers.forEach(center.removeObserver)
    }
}
