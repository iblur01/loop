import SwiftUI

/// Provenance de la séance : app ou appareil Santé, ou détection par le bracelet.
struct WorkoutSourcesCard: View {
    let session: WorkoutSession

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("today.source", tableName: "Today")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(WorkoutFormat.source(session))
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .deviceSurface()
        .accessibilityElement(children: .combine)
    }
}
