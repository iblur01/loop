import SwiftUI

// MARK: - DynamicWidget

/// One widget of a screen grid (spec design §6 #8, §7.0). Fixed priority per screen; a widget
/// whose data is missing is not rendered at all. The content closure is only evaluated when
/// the widget is available.
struct DynamicWidget: Identifiable {
    enum Span { case full, half }

    let id: String
    let priority: Int
    var span: Span = .full
    let isAvailable: Bool
    let content: () -> AnyView

    init<Content: View>(id: String, priority: Int, span: Span = .full, isAvailable: Bool,
                        @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.priority = priority
        self.span = span
        self.isAvailable = isAvailable
        self.content = { AnyView(content()) }
    }
}

// MARK: - DynamicWidgetGrid

/// Deterministic grid: available widgets sorted by priority; two consecutive half widgets share a
/// row, a lone half widget takes the full width. Accessibility text sizes collapse to one column.
/// No animated reordering while reading.
struct DynamicWidgetGrid: View {
    let widgets: [DynamicWidget]
    /// Entrance cascade; disabled when Reduce Motion is on.
    var animatesEntrance: Bool = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private struct Row: Identifiable {
        let items: [DynamicWidget]
        var id: String { items.map(\.id).joined(separator: "+") }
    }

    private var rows: [Row] {
        let available = widgets.filter(\.isAvailable).sorted { $0.priority < $1.priority }
        let oneColumn = dynamicTypeSize.isAccessibilitySize
        var rows: [Row] = []
        var pendingHalf: DynamicWidget?
        for widget in available {
            if widget.span == .half && !oneColumn {
                if let half = pendingHalf {
                    rows.append(Row(items: [half, widget]))
                    pendingHalf = nil
                } else {
                    pendingHalf = widget
                }
            } else {
                if let half = pendingHalf { rows.append(Row(items: [half])); pendingHalf = nil }
                rows.append(Row(items: [widget]))
            }
        }
        if let half = pendingHalf { rows.append(Row(items: [half])) }
        return rows
    }

    var body: some View {
        VStack(spacing: LoopMeasure.gridSpacing) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .top, spacing: LoopMeasure.gridSpacing) {
                    ForEach(row.items) { item in
                        item.content()
                            .frame(maxWidth: .infinity, maxHeight: row.items.count > 1 ? .infinity : nil, alignment: .topLeading)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .modifier(Entrance(index: index, appeared: appeared || !animated))
            }
        }
        .onAppear {
            guard animated else { return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appeared = true }
        }
    }

    private var animated: Bool { animatesEntrance && !reduceMotion }

    private struct Entrance: ViewModifier {
        let index: Int
        let appeared: Bool

        func body(content: Content) -> some View {
            content
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 14)
                .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.05 * Double(index)), value: appeared)
        }
    }
}
