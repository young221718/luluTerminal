import SwiftUI

struct TerminalWorkspaceActions {
    var find: (() -> Void)?
    var quickSwitch: (() -> Void)?
}

private struct TerminalWorkspaceActionsKey: FocusedValueKey {
    typealias Value = TerminalWorkspaceActions
}

extension FocusedValues {
    var terminalWorkspaceActions: TerminalWorkspaceActions? {
        get { self[TerminalWorkspaceActionsKey.self] }
        set { self[TerminalWorkspaceActionsKey.self] = newValue }
    }
}

public struct TerminalWorkspaceCommands: Commands {
    @FocusedValue(\.terminalWorkspaceActions) private var actions
    public init() {}

    public var body: some Commands {
        CommandMenu("찾기 · 이동") {
            Button("터미널에서 찾기…") { actions?.find?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions?.find == nil)
            Button("서버·탭 빠른 이동…") { actions?.quickSwitch?() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(actions?.quickSwitch == nil)
        }
    }
}
