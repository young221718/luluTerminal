import SwiftUI
import AppKit

enum PanelEdge {
    case sidebar, inspector
    var title: String { self == .sidebar ? "서버 목록" : "자원 패널" }
    @MainActor var range: ClosedRange<Double> {
        self == .sidebar ? MonitoringPreferences.sidebarWidthRange : MonitoringPreferences.inspectorWidthRange
    }
    var direction: Double { self == .sidebar ? 1 : -1 }
}

enum PanelLayout {
    static let dividerWidth = 16.0
    static let reservedWidth = 340 + 2 * dividerWidth

    static func fittedWidths(available: Double, sidebar: Double, inspector: Double) -> (sidebar: Double, inspector: Double) {
        let budget = max(0, available - reservedWidth)
        let leftMinimum = sidebar > 0 ? min(sidebar, 160) : 0
        let rightMinimum = inspector > 0 ? min(inspector, 220) : 0
        let extra = sidebar + inspector - leftMinimum - rightMinimum
        guard sidebar + inspector > budget, extra > 0 else { return (sidebar, inspector) }
        let scale = max(0, min(1, (budget - leftMinimum - rightMinimum) / extra))
        return (leftMinimum + (sidebar - leftMinimum) * scale,
                rightMinimum + (inspector - rightMinimum) * scale)
    }

    @MainActor static func draggedWidth(start: Double, translation: Double, edge: PanelEdge, maximum: Double) -> Double {
        let proposed = start + translation * edge.direction
        guard proposed >= edge.range.lowerBound / 2 else { return 0 }
        return min(max(edge.range.lowerBound, proposed), max(edge.range.lowerBound, maximum))
    }
}

struct PanelDivider: View {
    @EnvironmentObject private var appearance: AppearancePreferences
    let edge: PanelEdge
    @Binding var isVisible: Bool
    @Binding var savedWidth: Double
    @Binding var dragWidth: Double?
    let displayedWidth: Double
    let maximumWidth: Double
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void
    @ViewState private var startingWidth: Double?
    @ViewState private var hovering = false

    private var expanded: Bool { dragWidth.map { $0 > 0 } ?? isVisible }
    private var chevron: String {
        (edge == .sidebar) == expanded ? "chevron.left" : "chevron.right"
    }

    var body: some View {
        VStack(spacing: 0) {
            dragTarget.frame(height: 12)
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { isVisible.toggle() }
            } label: {
                Image(systemName: chevron).font(.system(size: 10, weight: .semibold))
                    .frame(width: PanelLayout.dividerWidth, height: 30)
                    .background(appearance.colors.panel, in: RoundedRectangle(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).stroke(appearance.colors.track, lineWidth: 1) }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(edge.title) \(expanded ? "접기" : "펼치기")")
            .accessibilityLabel("\(edge.title) \(expanded ? "접기" : "펼치기")")
            .accessibilityValue(expanded ? "펼침" : "접힘")
            dragTarget
        }
        .frame(width: PanelLayout.dividerWidth)
        .background {
            Rectangle().fill(hovering ? appearance.colors.accent.opacity(0.45) : appearance.colors.track)
                .frame(width: 1)
        }
        .background(appearance.colors.panel)
    }

    private var dragTarget: some View {
        Color.clear.contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { value in
                    if startingWidth == nil {
                        startingWidth = displayedWidth
                        // Freeze the other visible width to prevent a constrained layout feeding back into the drag.
                        onDragBegan()
                    }
                    dragWidth = PanelLayout.draggedWidth(start: startingWidth ?? 0,
                                                       translation: Double(value.translation.width),
                                                       edge: edge, maximum: maximumWidth)
                }
                .onEnded { value in
                    let width = PanelLayout.draggedWidth(start: startingWidth ?? displayedWidth,
                                                        translation: Double(value.translation.width),
                                                        edge: edge, maximum: maximumWidth)
                    if width > 0 { savedWidth = width }
                    isVisible = width > 0
                    dragWidth = nil
                    startingWidth = nil
                    onDragEnded()
                })
            .accessibilityHidden(true)
    }
}
