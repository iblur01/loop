import SwiftUI

/// Page de configuration du réveil bracelet (sous-page de `DeviceView`). Monochrome, calme, alignée
/// sur le langage visuel du tab Appareil : une surface de verre par bloc, un seul accent (statut).
struct AlarmView: View {
    @EnvironmentObject private var connection: DeviceConnectionViewModel
    @EnvironmentObject private var alarmController: SmartAlarmController
    @ObservedObject private var prefs = UserPreferences.shared

    private var weekdayOrder: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private var weekdayLabels: [String] { Calendar.current.veryShortStandaloneWeekdaySymbols }

    private var isConnected: Bool { connection.state.connected && connection.state.bonded }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                enabledToggle
                if prefs.alarmEnabled {
                    timeCard
                    weekdayCard
                    modeCard
                    if prefs.alarmMode == .smart { leadCard }
                    actions
                }
                footer
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .background(LoopColor.bgBase.ignoresSafeArea())
        .navigationTitle(NSLocalizedString("Réveil", tableName: "Base", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: prefs.alarmEnabled) { sync() }
        .onChange(of: prefs.alarmHour) { sync() }
        .onChange(of: prefs.alarmMinute) { sync() }
        .onChange(of: prefs.alarmWeekdays) { sync() }
        .onChange(of: prefs.alarmMode) { sync() }
        .onChange(of: prefs.alarmLeadMinutes) { sync() }
    }

    // MARK: - Sync config → bracelet

    private func sync() {
        if prefs.alarmEnabled {
            alarmController.arm(using: connection)
        } else {
            alarmController.disarm(using: connection)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "alarm.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(prefs.alarmEnabled ? Pop.green : .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("Réveil", tableName: "Base", comment: ""))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(statusLine)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deviceSurface(cornerRadius: 18)
    }

    private var statusLine: String {
        guard prefs.alarmEnabled else { return NSLocalizedString("Désactivé", tableName: "Base", comment: "") }
        let time = String(format: "%02d:%02d", prefs.alarmHour, prefs.alarmMinute)
        return String(format: NSLocalizedString("device.alarm.active", tableName: "Base", comment: ""), time, prefs.alarmWeekdaysSummary)
    }

    // MARK: - Toggle

    private var enabledToggle: some View {
        Toggle(isOn: $prefs.alarmEnabled) {
            Text(NSLocalizedString("Activer l'alarme", tableName: "Base", comment: ""))
                .font(.system(size: 15, weight: .medium))
        }
        .tint(Pop.green)
        .padding(16)
        .deviceSurface(cornerRadius: 18)
    }

    // MARK: - Time

    private var timeCard: some View {
        DatePicker(
            NSLocalizedString("Heure", tableName: "Base", comment: ""),
            selection: timeBinding,
            displayedComponents: .hourAndMinute
        )
        .datePickerStyle(.wheel)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .padding(8)
        .deviceSurface(cornerRadius: 18)
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: prefs.alarmHour, minute: prefs.alarmMinute, second: 0, of: Date()) ?? Date()
            },
            set: { newValue in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                prefs.alarmHour = comps.hour ?? prefs.alarmHour
                prefs.alarmMinute = comps.minute ?? prefs.alarmMinute
            }
        )
    }

    // MARK: - Weekdays

    private var weekdayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Répétition", tableName: "Base", comment: ""))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(weekdayOrder, id: \.self) { day in
                    weekdayChip(day)
                }
            }
            if prefs.alarmWeekdays.isEmpty {
                Text(NSLocalizedString("Une seule fois — la prochaine occurrence de l'heure.", tableName: "Base", comment: ""))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deviceSurface(cornerRadius: 18)
    }

    private func weekdayChip(_ day: Int) -> some View {
        let isOn = prefs.alarmWeekdays.contains(day)
        return Text(weekdayLabels[day - 1])
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isOn ? Color.white : .primary)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(
                Circle()
                    .fill(isOn ? Pop.green : Color.primary.opacity(0.06))
                    .frame(width: 38, height: 38)
            )
            .pressable {
                if isOn { prefs.alarmWeekdays.remove(day) } else { prefs.alarmWeekdays.insert(day) }
            }
    }

    // MARK: - Mode

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(NSLocalizedString("Mode", tableName: "Base", comment: ""), selection: $prefs.alarmMode) {
                Text(AlarmMode.regular.label).tag(AlarmMode.regular)
                Text(AlarmMode.smart.label).tag(AlarmMode.smart)
            }
            .pickerStyle(.segmented)
            Text(NSLocalizedString("Le mode intelligent utilise un flux HR dense pendant la fenêtre de réveil pour te réveiller en sommeil léger.", tableName: "Base", comment: ""))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .deviceSurface(cornerRadius: 18)
    }

    // MARK: - Lead time

    private var leadCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(format: NSLocalizedString("device.alarm.window", tableName: "Base", comment: ""), String(prefs.alarmLeadMinutes)))
                .font(.system(size: 14, weight: .medium))
            Slider(
                value: Binding(
                    get: { Double(prefs.alarmLeadMinutes) },
                    set: { prefs.alarmLeadMinutes = Int($0) }
                ),
                in: Double(UserPreferences.minAlarmLeadMinutes)...Double(UserPreferences.maxAlarmLeadMinutes),
                step: 5
            )
            .tint(Pop.green)
        }
        .padding(16)
        .deviceSurface(cornerRadius: 18)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                alarmController.testBuzz(using: connection)
            } label: {
                Label(NSLocalizedString("Tester la vibration", tableName: "Base", comment: ""), systemImage: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.glass)
            .disabled(!isConnected)

            Button(role: .destructive) {
                alarmController.disarm(using: connection)
            } label: {
                Text(NSLocalizedString("Désactiver sur le bracelet", tableName: "Base", comment: ""))
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .disabled(!isConnected)

            if !isConnected {
                Text(NSLocalizedString("Bracelet non connecté — tes réglages seront appliqués à la prochaine connexion.", tableName: "Base", comment: ""))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        Text(String(format: NSLocalizedString("device.alarm.explanation", tableName: "Base", comment: ""), String(prefs.alarmLeadMinutes)))
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }
}

#Preview("Smart, connecté") {
    let prefs = UserPreferences.shared
    prefs.alarmEnabled = true
    prefs.alarmMode = .smart
    prefs.alarmWeekdays = [2, 3, 4, 5, 6]
    let conn = DeviceConnectionViewModel()
    conn.state.connected = true
    conn.state.bonded = true
    return NavigationStack { AlarmView() }
        .environmentObject(conn)
        .environmentObject(SmartAlarmController())
}

#Preview("Régulier, déconnecté") {
    let prefs = UserPreferences.shared
    prefs.alarmEnabled = true
    prefs.alarmMode = .regular
    prefs.alarmWeekdays = []
    return NavigationStack { AlarmView() }
        .environmentObject(DeviceConnectionViewModel())
        .environmentObject(SmartAlarmController())
}
