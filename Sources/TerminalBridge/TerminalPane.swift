import AppKit
import GhosttyTerminal
import SwiftUI

public struct TerminalPane: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var host: TerminalHost
    private let id: UUID
    private let style: TerminalStyle

    public init(host: TerminalHost, id: UUID, style: TerminalStyle = .default) {
        self.host = host
        self.id = id
        self.style = style
    }

    public func makeNSView(context: Context) -> NSView {
        host.setStyle(style)
        host.setColorScheme(colorScheme == .dark ? .dark : .light)
        let container = TerminalContainer()
        show(in: container)
        return container
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        host.setStyle(style)
        host.setColorScheme(colorScheme == .dark ? .dark : .light)
        if let container = nsView as? TerminalContainer { show(in: container) }
    }

    private func show(in container: TerminalContainer) {
        let host = self.host
        let id = self.id
        let view = host.view(for: id)
        container.show(view, isCurrent: { [weak host, weak view] in
            guard let host, let view else { return false }
            return host.view(for: id) === view
        })
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? TerminalContainer)?.show(nil)
    }
}

@MainActor final class TerminalContainer: NSView {
    private weak var terminal: TerminalView?

    func show(_ next: TerminalView?, isCurrent: @escaping () -> Bool = { true }) {
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
            guard let self, let next, self.terminal === next, next.superview === self, isCurrent(),
                  let window = self.window, window.isKeyWindow, window.attachedSheet == nil else { return }
            // Search and quick-switch text fields own focus until explicitly closed.
            if let responder = window.firstResponder,
               responder !== window, responder !== self, !(responder is TerminalView) { return }
            window.makeFirstResponder(next)
        }
    }
}
