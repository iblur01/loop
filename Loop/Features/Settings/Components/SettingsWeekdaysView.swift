import SwiftUI

/// Choix des jours de l'alarme (indices `Calendar` 1...7, 1 = dimanche). Aucun jour = alarme unique.
struct SettingsWeekdaysView: View {
    @ObservedObject var prefs: UserPreferences

    /// Ordre lundi d'abord.
    private let order = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ProfileGroup {
                    ForEach(order, id: \.self) { day in
                        if day != order.first { ProfileHairline(inset: ProfileRowMetrics.horizontalPadding) }
                        row(day)
                    }
                }
                ProfileFootnote(text: NSLocalizedString("settings.alarm.days.footer", tableName: "Base", comment: ""))
            }
            .padding(.horizontal, LoopMeasure.screenGutter)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(LoopColor.bgBase)
        .navigationTitle(NSLocalizedString("settings.alarm.days", tableName: "Base", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ day: Int) -> some View {
        let selected = prefs.alarmWeekdays.contains(day)
        return Button {
            toggle(day)
        } label: {
            HStack {
                Text(Calendar.current.weekdaySymbols[day - 1].capitalized)
                    .font(LoopType.body)
                    .foregroundStyle(LoopColor.textPrimary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(LoopType.label)
                        .foregroundStyle(Color.green)
                }
            }
            .padding(.horizontal, ProfileRowMetrics.horizontalPadding)
            .frame(minHeight: ProfileRowMetrics.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toggle(_ day: Int) {
        if prefs.alarmWeekdays.contains(day) {
            prefs.alarmWeekdays.remove(day)
        } else {
            prefs.alarmWeekdays.insert(day)
        }
    }
}
