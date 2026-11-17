import SwiftUI

/// What to do tonight, prescriptive. Two tiles (bed / wake, real times from
/// UserPreferences — no hard-coded 07:00), the rolling 7-day debt and tonight's need
/// as captions, and a coach line carrying the page's one accent (band colour).
struct SleepTonightPlan: View {
    let model: SleepCoachModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WidgetLabel(symbol: "moon.zzz.fill", title: String(localized: "today.plan.de.ce.soir", table: "Today"), tint: model.band.color)

            HStack(alignment: .top, spacing: 14) {
                tile(TodayL.text("today.final.sleep.bedtime"), model.bedtimeText)
                Rectangle().fill(.secondary.opacity(0.16)).frame(width: 1)
                tile(TodayL.text("today.final.sleep.wake"), model.wakeText)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(model.debtText)
                Text(model.neededText)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.tertiary)

            Divider().overlay(.secondary.opacity(0.16))

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(model.band.color)
                    .padding(.top, 1)
                Text(model.coachingMessage)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deviceSurface()
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    SleepTonightPlan(model: SleepCoachModel(metric: .sleepPreview(score: 72)))
        .padding()
        .background(Color(.systemGroupedBackground))
}
