import SwiftUI

/// Réveil cible : une roue d'heure, rien d'autre.
struct WakeTargetView: View {
    @ObservedObject var prefs: UserPreferences

    var body: some View {
        ProfileGoalPage(title: NSLocalizedString("profile.goal.wake", tableName: "Base", comment: ""),
                        subtitle: NSLocalizedString("profile.wake.subtitle", tableName: "Base", comment: "")) {
            DatePicker(NSLocalizedString("profile.goal.wake", tableName: "Base", comment: ""),
                       selection: timeBinding, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, ProfileRowMetrics.horizontalPadding)
        }
    }

    private var timeBinding: Binding<Date> {
        Binding {
            prefs.wakeDateToday
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            prefs.wakeHour = parts.hour ?? prefs.wakeHour
            prefs.wakeMinute = parts.minute ?? prefs.wakeMinute
        }
    }
}

#Preview {
    NavigationStack { WakeTargetView(prefs: .shared) }
}
