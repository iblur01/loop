import SwiftUI

/// Card Today affichée quand l'alarme est active : l'heure dominante, les jours et le mode en légende.
/// Tap → ouvre la page de configuration du réveil.
struct AlarmWidget: View {
    @ObservedObject var prefs: UserPreferences

    var body: some View {
        NavigationLink(value: TodayRoute.alarm) {
            VStack(alignment: .leading, spacing: 10) {
                WidgetLabel(symbol: "alarm.fill", title: String(localized: "today.reveil", table: "Today"), trailing: nil, showsChevron: true)
                WidgetMetric(value: timeText)
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .widgetSurface()
        }
        .buttonStyle(.plain)
    }

    private var timeText: String {
        String(format: "%02d:%02d", prefs.alarmHour, prefs.alarmMinute)
    }

    private var caption: String {
        let days = prefs.alarmWeekdaysSummary
        switch prefs.alarmMode {
        case .smart:   return TodayL.format("today.alarm.smart", days, String(prefs.alarmLeadMinutes))
        case .regular: return TodayL.format("today.alarm.regular", days)
        case .off:     return days
        }
    }
}

#Preview {
    let prefs = UserPreferences.shared
    prefs.alarmEnabled = true
    prefs.alarmMode = .smart
    prefs.alarmHour = 7
    prefs.alarmMinute = 0
    prefs.alarmWeekdays = [2, 3, 4, 5, 6]
    return NavigationStack {
        AlarmWidget(prefs: prefs).padding()
    }
}
