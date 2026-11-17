import SwiftUI
import UIKit

/// Réglages de l'application (pas de la personne : âge, taille, poids, FC max et objectifs restent sur Profil).
/// Atteint depuis Profil. N'expose que des réglages qui existent dans `UserPreferences`.
struct SettingsView: View {
    @ObservedObject var prefs: UserPreferences
    var onOpenBackup: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LoopMeasure.sectionSpacing) {
                alarmSection
                displaySection
                dataSection
            }
            .padding(.horizontal, LoopMeasure.screenGutter)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(LoopColor.bgBase)
        .tint(Color.green)
        .navigationTitle(NSLocalizedString("settings.title", tableName: "Base", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Réveil

    private var alarmSection: some View {
        let enabledTitle = NSLocalizedString("settings.alarm.enabled", tableName: "Base", comment: "")
        let modeTitle = NSLocalizedString("settings.alarm.mode", tableName: "Base", comment: "")
        let timeTitle = NSLocalizedString("settings.alarm.time", tableName: "Base", comment: "")
        let windowTitle = NSLocalizedString("settings.alarm.window", tableName: "Base", comment: "")
        return VStack(alignment: .leading, spacing: 8) {
            ProfileSection(title: sectionTitle("settings.alarm.section")) {
                ProfileGroup {
                    SettingsRow(title: enabledTitle, symbol: "alarm", category: .wake) {
                        Toggle(enabledTitle, isOn: $prefs.alarmEnabled).labelsHidden()
                    }
                    if prefs.alarmEnabled {
                        hairline
                        SettingsRow(title: modeTitle, symbol: "moon.zzz", category: .wake) {
                            Picker(modeTitle, selection: $prefs.alarmMode) {
                                ForEach(AlarmMode.allCases, id: \.self) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        hairline
                        SettingsRow(title: timeTitle, symbol: "clock", category: .wake) {
                            DatePicker(timeTitle, selection: timeBinding, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                        hairline
                        NavigationLink {
                            SettingsWeekdaysView(prefs: prefs)
                        } label: {
                            SettingsRow(title: NSLocalizedString("settings.alarm.days", tableName: "Base", comment: ""),
                                        symbol: "calendar", category: .wake) {
                                SettingsDisclosure(value: prefs.alarmWeekdaysSummary)
                            }
                        }
                        .buttonStyle(.plain)
                        if prefs.alarmMode == .smart {
                            hairline
                            SettingsRow(title: windowTitle, symbol: "timer", category: .wake) {
                                HStack(spacing: 8) {
                                    Text(String(format: NSLocalizedString("settings.alarm.window.value", tableName: "Base", comment: ""),
                                                prefs.alarmLeadMinutes))
                                        .font(LoopType.body)
                                        .foregroundStyle(LoopColor.textSecondary)
                                        .monospacedDigit()
                                        .lineLimit(1)
                                    Stepper(windowTitle, value: $prefs.alarmLeadMinutes,
                                            in: UserPreferences.minAlarmLeadMinutes...UserPreferences.maxAlarmLeadMinutes,
                                            step: 5)
                                        .labelsHidden()
                                        .fixedSize()
                                }
                            }
                        }
                    }
                }
            }
            ProfileFootnote(text: NSLocalizedString("settings.alarm.footer", tableName: "Base", comment: ""))
        }
    }

    // MARK: - Affichage

    private var displaySection: some View {
        let unitsTitle = NSLocalizedString("settings.units", tableName: "Base", comment: "")
        return VStack(alignment: .leading, spacing: 8) {
            ProfileSection(title: sectionTitle("settings.display.section")) {
                ProfileGroup {
                    SettingsRow(title: unitsTitle, symbol: "ruler", category: .display) {
                        Picker(unitsTitle, selection: $prefs.unitSystem) {
                            ForEach(UserPreferences.UnitSystem.allCases, id: \.self) { unit in
                                Text(unit.label).tag(unit)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    hairline
                    systemRow(title: "settings.appearance", symbol: "circle.lefthalf.filled")
                    hairline
                    systemRow(title: "settings.language", symbol: "globe")
                }
            }
            ProfileFootnote(text: NSLocalizedString("settings.display.footer", tableName: "Base", comment: ""))
        }
    }

    /// Ligne en lecture seule : la valeur suit l'iPhone. Un tap ouvre les Réglages système.
    private func systemRow(title: String, symbol: String) -> some View {
        Button {
            openSystemSettings()
        } label: {
            SettingsRow(title: NSLocalizedString(title, tableName: "Base", comment: ""),
                        symbol: symbol, category: .display) {
                SettingsDisclosure(value: NSLocalizedString("settings.system.value", tableName: "Base", comment: ""))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Données

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProfileSection(title: sectionTitle("settings.data.section")) {
                ProfileGroup {
                    Button {
                        openSystemSettings()
                    } label: {
                        SettingsRow(title: NSLocalizedString("settings.health.permissions", tableName: "Base", comment: ""),
                                    symbol: "hand.raised", category: .data) {
                            SettingsDisclosure()
                        }
                    }
                    .buttonStyle(.plain)
                    hairline
                    Button {
                        onOpenBackup()
                    } label: {
                        SettingsRow(title: NSLocalizedString("settings.data.backup", tableName: "Base", comment: ""),
                                    symbol: "square.and.arrow.up", category: .data) {
                            SettingsDisclosure()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            ProfileFootnote(text: NSLocalizedString("settings.health.footer", tableName: "Base", comment: ""))
        }
    }

    // MARK: - Helpers

    private var hairline: some View { ProfileHairline(inset: SettingsMetrics.hairlineInset) }

    private func sectionTitle(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Base", comment: "")
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private var timeBinding: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: prefs.alarmHour, minute: prefs.alarmMinute, second: 0, of: Date()) ?? Date()
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            prefs.alarmHour = parts.hour ?? UserPreferences.defaultAlarmHour
            prefs.alarmMinute = parts.minute ?? UserPreferences.defaultAlarmMinute
        }
    }
}
