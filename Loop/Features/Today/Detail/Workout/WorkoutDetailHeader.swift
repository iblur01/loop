import SwiftUI

/// En-tête : carte du parcours si un tracé existe, puis icône du sport, titre et plage horaire.
struct WorkoutDetailHeader: View {
    let session: WorkoutSession
    var route: WorkoutRoute? = nil

    @ScaledMetric(relativeTo: .title2) private var badgeSize: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkoutRouteMap(route: route)

            HStack(spacing: 14) {
                Image(systemName: WorkoutFormat.symbol(session))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(WorkoutFormat.sport(session).tint)
                    .frame(width: badgeSize, height: badgeSize)
                    .loopCard(.nested, cornerRadius: 16)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(WorkoutFormat.title(session))
                        .font(.title.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text(WorkoutFormat.timeRange(session))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
