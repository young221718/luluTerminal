import SwiftUI
import UniformTypeIdentifiers

struct ServerReorderModifier: ViewModifier {
    let id: UUID
    let previewBackground: Color
    @ViewState private var rowSize = CGSize.zero
    let move: @MainActor (UUID, Bool) -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onGeometryChange(for: CGSize.self) { $0.size } action: { rowSize = $0 }
            .onDrag {
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .ownProcess) { completion in
                    completion(Data(id.uuidString.utf8), nil)
                    return nil
                }
                return provider
            } preview: {
                content
                    .frame(width: rowSize.width, height: rowSize.height)
                    .background(previewBackground, in: RoundedRectangle(cornerRadius: 7))
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

@available(macOS 27, *)
struct ServerReorderMove {
    let id: UUID
    let targetID: UUID
    let after: Bool

    init?(sources: [UUID], destination: ReorderDifference<UUID, ReorderableSingleCollectionIdentifier>.Destination.Position,
          serverIDs: [UUID]) {
        guard sources.count == 1, let id = sources.first,
              Set(serverIDs).count == serverIDs.count,
              let source = serverIDs.firstIndex(of: id) else { return nil }
        switch destination {
        case .before(let targetID):
            guard let target = serverIDs.firstIndex(of: targetID),
                  target != source, target != source + 1 else { return nil }
            self.targetID = targetID
            after = false
        case .end:
            guard let targetID = serverIDs.last, targetID != id else { return nil }
            self.targetID = targetID
            after = true
        }
        self.id = id
    }
}
