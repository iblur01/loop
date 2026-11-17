import SwiftUI

/// Grille des mesures présentes (deux colonnes, une seule aux tailles d'accessibilité).
/// Masquée s'il n'y a aucune mesure : un texte court le dit à la place.
struct WorkoutMetricsGrid: View {
    let metrics: [WorkoutMetric]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    var body: some View {
        if metrics.isEmpty {
            Text("today.aucune.mesure.pour.cette.seance", tableName: "Today")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .deviceSurface()
        } else {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(metrics) { WorkoutMetricTile(metric: $0) }
            }
        }
    }
}
