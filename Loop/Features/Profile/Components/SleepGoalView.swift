import SwiftUI

/// Objectif de sommeil : un curseur de 5 h à 10 h par pas de 15 minutes.
struct SleepGoalView: View {
    @ObservedObject var prefs: UserPreferences

    var body: some View {
        ProfileGoalPage(title: NSLocalizedString("profile.goal.sleep", tableName: "Base", comment: ""),
                        subtitle: NSLocalizedString("profile.sleep.subtitle", tableName: "Base", comment: "")) {
            ProfileGoalValueRow(title: NSLocalizedString("profile.goal.sleep", tableName: "Base", comment: ""),
                                value: GoalFormat.sleepText(minutes: prefs.sleepTargetMin))
            ProfileHairline(inset: ProfileRowMetrics.horizontalPadding)
            Slider(
                value: $prefs.sleepTargetMin,
                in: UserPreferences.minSleepTargetMin...UserPreferences.maxSleepTargetMin,
                step: 15
            ) {
                Text(NSLocalizedString("profile.sleep.slider", tableName: "Base", comment: ""))
            }
            .padding(.horizontal, ProfileRowMetrics.horizontalPadding)
            .frame(minHeight: ProfileRowMetrics.height)
        }
    }
}

#Preview {
    NavigationStack { SleepGoalView(prefs: .shared) }
}
