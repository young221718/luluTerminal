import AppKit
import GhosttyTerminal
import SwiftUI

public struct TerminalPane: NSViewRepresentable {
    @ObservedObject private var host: TerminalHost
    private let id: UUID

    public init(host: TerminalHost, id: UUID) {
        self.host = host
        self.id = id
    }

    public func makeNSView(context: Context) -> NSView {
        let container = TerminalContainer()
        container.show(host.view(for: id))
        return container
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TerminalContainer)?.show(host.view(for: id))
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? TerminalContainer)?.show(nil)
    }
}

@MainActor final class TerminalContainer: NSView {
    private weak var terminal: TerminalView?

    func show(_ next: TerminalView?) {
        if terminal === next, next == nil || next?.superview === self { return }
        // SwiftUI can attach a cached surface to its new container before
        // dismantling the old one. Only its current owner may hide/remove it.
        if let terminal, terminal.superview === self {
            terminal.setSurfaceVisible(false)
            terminal.removeFromSuperview()
        }
        terminal = next
        guard let next else { return }
        next.removeFromSuperview()
        next.frame = bounds
        next.autoresizingMask = [.width, .height]
        addSubview(next)
        next.setSurfaceVisible(true)
        DispatchQueue.main.async { [weak self, weak next] in
            guard let self, let next, self.terminal === next, next.superview === self else { return }
            self.window?.makeFirstResponder(next)
        }
    }
}
