import SwiftUI
import InfraCore

@MainActor
struct SSHKeySetupQueue {
    private(set) var pending: [SSHKeySetupRequest] = []
    private var completed = false

    mutating func saveProfile(_ profile: ServerProfile, using model: AppModel) throws {
        let previousIDs = Set(model.workspace.servers.first { $0.id == profile.id }?.accounts.map(\.id) ?? [])
        try model.saveProfile(profile)
        pending.removeAll()
        guard !model.isDemo,
              let saved = model.workspace.servers.first(where: { $0.id == profile.id && $0.kind == .ssh }) else { return }
        pending = saved.accounts.filter { !previousIDs.contains($0.id) && $0.authMethod == .pendingKey }
            .map { SSHKeySetupRequest(serverID: saved.id, accountID: $0.id) }
    }

    mutating func next() -> SSHKeySetupRequest? {
        completed = false
        return pending.isEmpty ? nil : pending.removeFirst()
    }
    mutating func markCompleted() { completed = true }
    mutating func dismissed() -> SSHKeySetupRequest? {
        guard completed else { pending.removeAll(); return nil }
        return next()
    }
}

struct ProfileSSHKeySheets: ViewModifier {
    @ObservedObject var model: AppModel
    @Binding var showProfile: Bool
    let editingProfile: ServerProfile?
    @Binding var keySetupRequest: SSHKeySetupRequest?
    let disconnect: (UUID) -> Void
    @ViewState private var queue = SSHKeySetupQueue()

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showProfile, onDismiss: { keySetupRequest = queue.next() }) {
                ProfileEditorSheet(profile: editingProfile,
                                   tabs: model.workspace.tabs.filter { $0.serverID == editingProfile?.id },
                                   demo: model.isDemo, model: model, queue: $queue, disconnect: disconnect)
                .id(editingProfile?.id)
            }
            .sheet(item: $keySetupRequest, onDismiss: { keySetupRequest = queue.dismissed() }) { request in
                SSHKeySetupView(model: model, request: request, onComplete: { queue.markCompleted() })
                    .id(request.id)
            }
    }
}

private struct ProfileEditorSheet: View {
    let profile: ServerProfile?
    let tabs: [TerminalTab]
    let demo: Bool
    @StateObject private var context: ProfileEditorSaveContext

    init(profile: ServerProfile?, tabs: [TerminalTab], demo: Bool, model: AppModel,
         queue: Binding<SSHKeySetupQueue>, disconnect: @escaping (UUID) -> Void) {
        self.profile = profile
        self.tabs = tabs
        self.demo = demo
        _context = StateObject(wrappedValue: ProfileEditorSaveContext(model: model, queue: queue, disconnect: disconnect))
    }

    var body: some View {
        ProfileEditorPresentation(profile: profile, tabs: tabs, demo: demo, context: context).equatable()
    }
}

// One presentation owns its save context. The root's model and disconnect owner
// are stable StateObjects; a new sheet captures a new context and callback.
@MainActor final class ProfileEditorSaveContext: ObservableObject {
    private let model: AppModel
    private let queue: Binding<SSHKeySetupQueue>
    private let disconnect: (UUID) -> Void

    init(model: AppModel, queue: Binding<SSHKeySetupQueue>, disconnect: @escaping (UUID) -> Void) {
        self.model = model
        self.queue = queue
        self.disconnect = disconnect
    }

    func save(_ profile: ServerProfile) throws {
        let previousTabIDs = model.workspace.tabs.filter { $0.serverID == profile.id }.map(\.id)
        var updatedQueue = queue.wrappedValue
        try updatedQueue.saveProfile(profile, using: model)
        queue.wrappedValue = updatedQueue
        for id in previousTabIDs { disconnect(id) }
    }
}

struct ProfileEditorPresentation: View, Equatable {
    let profile: ServerProfile?
    let tabs: [TerminalTab]
    let demo: Bool
    let context: ProfileEditorSaveContext

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.profile == rhs.profile && lhs.tabs == rhs.tabs && lhs.demo == rhs.demo && lhs.context === rhs.context
    }

    var body: some View {
        ProfileEditor(profile: profile, tabs: tabs, demo: demo, save: context.save)
    }
}
