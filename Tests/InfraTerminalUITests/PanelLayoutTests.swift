import Testing
@testable import InfraTerminalUI

@MainActor struct PanelLayoutTests {
    @Test func narrowWindowReservesTerminalSpaceWithoutChangingPreferredWidths() {
        let compact = PanelLayout.fittedWidths(available: 800, sidebar: 320, inspector: 400)
        #expect(compact.sidebar >= 160)
        #expect(compact.inspector >= 220)
        #expect(compact.sidebar + compact.inspector + PanelLayout.reservedWidth <= 800.001)
        let wide = PanelLayout.fittedWidths(available: 1280, sidebar: 320, inspector: 400)
        #expect(wide.sidebar == 320)
        #expect(wide.inspector == 400)
        let closed = PanelLayout.fittedWidths(available: 800, sidebar: 0, inspector: 400)
        #expect(closed.sidebar == 0)
        #expect(closed.inspector == 400)
    }

    @Test func constrainedDragKeepsOppositeWidthPinnedAcrossEventsAndCommit() {
        let initial = PanelLayout.fittedWidths(available: 1000, sidebar: 320, inspector: 400)
        let opposite = initial.inspector
        let maximum = 1000 - PanelLayout.reservedWidth - opposite
        var current = initial
        for _ in 0..<8 {
            let dragged = PanelLayout.draggedWidth(start: initial.sidebar, translation: -20,
                                                  edge: .sidebar, maximum: maximum)
            current = PanelLayout.fittedWidths(available: 1000, sidebar: dragged, inspector: opposite)
            #expect(abs(current.sidebar - (initial.sidebar - 20)) < 0.001)
            #expect(abs(current.inspector - opposite) < 0.001)
        }
        let committed = PanelLayout.fittedWidths(available: 1000, sidebar: current.sidebar, inspector: opposite)
        #expect(abs(committed.sidebar - current.sidebar) < 0.001)
        #expect(abs(committed.inspector - current.inspector) < 0.001)
    }

    @Test func draggingEitherEdgeCanResizeCollapseAndReopen() {
        #expect(PanelLayout.draggedWidth(start: 190, translation: 70, edge: .sidebar, maximum: 320) == 260)
        #expect(PanelLayout.draggedWidth(start: 240, translation: -70, edge: .inspector, maximum: 400) == 310)
        #expect(PanelLayout.draggedWidth(start: 190, translation: -120, edge: .sidebar, maximum: 320) == 0)
        #expect(PanelLayout.draggedWidth(start: 240, translation: 140, edge: .inspector, maximum: 400) == 0)
        #expect(PanelLayout.draggedWidth(start: 0, translation: 100, edge: .sidebar, maximum: 320) == 160)
        #expect(PanelLayout.draggedWidth(start: 0, translation: -140, edge: .inspector, maximum: 400) == 220)
        #expect(PanelLayout.draggedWidth(start: 240, translation: -500, edge: .inspector, maximum: 300) == 300)
    }
}
