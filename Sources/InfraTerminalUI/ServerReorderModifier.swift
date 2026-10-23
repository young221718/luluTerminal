import SwiftUI
import UniformTypeIdentifiers

struct ServerReorderModifier: ViewModifier {
    let id: UUID
    let move: @MainActor (UUID, Bool) -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onDrag {
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .ownProcess) { completion in
                    completion(Data(id.uuidString.utf8), nil)
                    return nil
                }
                return provider
            }
            .onDrop(of: [UTType.utf8PlainText], delegate: ServerOrderDropDelegate(move: move))
    }
}

private struct ServerOrderDropDelegate: DropDelegate {
    let move: @MainActor (UUID, Bool) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [UTType.utf8PlainText])
        guard providers.count == 1, let provider = providers.first else { return false }
        let after = info.location.y >= 26.5
        provider.loadDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier) { data, _ in
            Task { @MainActor in
                guard let data, data.count == 36, let value = String(data: data, encoding: .utf8),
                      let id = UUID(uuidString: value) else { return }
                move(id, after)
            }
        }
        return true
    }
}
