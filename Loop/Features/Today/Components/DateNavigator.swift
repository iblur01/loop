import SwiftUI

// MARK: - Molecule

struct DateNavigator: View {
    let metrics: [DailySnapshot]
    @Binding var selectedDay: String?

    private var model: DateNavigatorModel {
        DateNavigatorModel(metrics: metrics, selectedDay: selectedDay)
    }

    var body: some View {
        HStack(spacing: 2) {
            DateNavigatorArrowButton(
                direction: .previous,
                isEnabled: model.canMoveBackward
            ) {
                selectedDay = model.dayMoving(by: -1)
            }

            DateNavigatorPicker(
                title: model.displayTitle,
                isEnabled: model.hasDays,
                selectedDate: model.selectedDate,
                dateRange: model.dateRange
            ) { date in
                selectedDay = model.nearestDay(to: date)
            }

            DateNavigatorArrowButton(
                direction: .next,
                isEnabled: model.canMoveForward
            ) {
                selectedDay = model.dayMoving(by: 1)
            }
        }
        // Pas de verre propre : l'item de toolbar reçoit déjà le verre système (pas de verre sur verre).
        .fixedSize()
        .onAppear(perform: ensureSelectedDay)
        .onChange(of: metrics.map(\.date)) {
            ensureSelectedDay()
        }
    }

    private func ensureSelectedDay() {
        selectedDay = model.validSelectedDay
    }
}

// MARK: - Atoms

private struct DateNavigatorArrowButton: View {
    let direction: DateNavigatorDirection
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: direction.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isEnabled ? .secondary : .quaternary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(direction.accessibilityLabel)
    }
}

private struct DateNavigatorPicker: View {
    let title: String
    let isEnabled: Bool
    let selectedDate: Date
    let dateRange: ClosedRange<Date>
    let onSelect: (Date) -> Void

    @State private var isPresented = false
    @State private var pickerDate: Date

    init(
        title: String,
        isEnabled: Bool,
        selectedDate: Date,
        dateRange: ClosedRange<Date>,
        onSelect: @escaping (Date) -> Void
    ) {
        self.title = title
        self.isEnabled = isEnabled
        self.selectedDate = selectedDate
        self.dateRange = dateRange
        self.onSelect = onSelect
        _pickerDate = State(initialValue: selectedDate)
    }

    var body: some View {
        Button {
            pickerDate = selectedDate
            isPresented = true
        } label: {
            DateNavigatorTrigger(title: title)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("Choisir la date")
        .accessibilityValue(title)
        .popover(isPresented: $isPresented) {
            DatePicker(
                "",
                selection: $pickerDate,
                in: dateRange,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .tint(.primary)
            .padding(12)
            .frame(width: 320)
            .presentationCompactAdaptation(.popover)
            .onChange(of: pickerDate) { _, newValue in
                onSelect(newValue)
                isPresented = false
            }
        }
    }
}

private struct DateNavigatorTrigger: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 44)
        .contentShape(Capsule())
    }
}

// MARK: - Presentation Model

private struct DateNavigatorModel {
    let sortedDays: [String]
    let selectedDay: String?

    init(metrics: [DailySnapshot], selectedDay: String?) {
        self.sortedDays = metrics.map(\.date).sorted()
        self.selectedDay = selectedDay
    }

    var hasDays: Bool {
        !sortedDays.isEmpty
    }

    var selectedIndex: Int? {
        guard hasDays else { return nil }
        let day = selectedDay ?? sortedDays.last
        return sortedDays.firstIndex { $0 == day } ?? sortedDays.indices.last
    }

    var validSelectedDay: String? {
        guard hasDays else { return nil }
        guard let selectedDay, sortedDays.contains(selectedDay) else {
            return sortedDays.last
        }
        return selectedDay
    }

    var displayTitle: String {
        guard let selectedDay = validSelectedDay, let date = Self.parseDay(selectedDay) else {
            return String(localized: "today.aujourd.hui", table: "Today")
        }
        if Calendar.current.isDateInToday(date) { return String(localized: "today.aujourd.hui", table: "Today") }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "today.hier", table: "Today") }
        return Self.titleFormatter.string(from: date).capitalized
    }

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()

    var selectedDate: Date {
        if let day = validSelectedDay, let date = Self.parseDay(day) {
            return date
        }
        return Date()
    }

    var dateRange: ClosedRange<Date> {
        guard
            let first = sortedDays.first.flatMap(Self.parseDay),
            let last = sortedDays.last.flatMap(Self.parseDay),
            first <= last
        else {
            let now = Date()
            return now...now
        }
        return first...last
    }

    func nearestDay(to date: Date) -> String? {
        guard !sortedDays.isEmpty else { return nil }
        let target = Self.dayFormatter.string(from: date)
        if sortedDays.contains(target) { return target }
        return sortedDays.min { lhs, rhs in
            guard
                let lDate = Self.parseDay(lhs),
                let rDate = Self.parseDay(rhs)
            else { return false }
            return abs(lDate.timeIntervalSince(date)) < abs(rDate.timeIntervalSince(date))
        }
    }

    var canMoveBackward: Bool {
        guard let selectedIndex else { return false }
        return selectedIndex > sortedDays.startIndex
    }

    var canMoveForward: Bool {
        guard let selectedIndex else { return false }
        return selectedIndex < sortedDays.index(before: sortedDays.endIndex)
    }

    func dayMoving(by offset: Int) -> String? {
        guard let selectedIndex else { return validSelectedDay }
        let nextIndex = sortedDays.index(selectedIndex, offsetBy: offset)
        guard sortedDays.indices.contains(nextIndex) else { return validSelectedDay }
        return sortedDays[nextIndex]
    }

    private static func parseDay(_ day: String) -> Date? {
        dayFormatter.date(from: day)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private enum DateNavigatorDirection {
    case previous
    case next

    var systemImage: String {
        switch self {
        case .previous: return "chevron.left"
        case .next: return "chevron.right"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .previous: return String(localized: "today.jour.precedent", table: "Today")
        case .next: return String(localized: "today.jour.suivant", table: "Today")
        }
    }
}

#Preview {
    DateNavigatorPreview()
}

private struct DateNavigatorPreview: View {
    @State private var selectedDay: String?

    var body: some View {
        DateNavigator(
            metrics: [
                DailySnapshot.preview(date: "2026-06-12"),
                DailySnapshot.preview(date: "2026-06-13"),
                DailySnapshot.preview(date: "2026-06-14")
            ],
            selectedDay: $selectedDay
        )
        .padding()
        .background(Color(.systemGroupedBackground))
    }
}

private extension DailySnapshot {
    static func preview(date: String) -> DailySnapshot {
        DailySnapshot(
            date: date,
            totalSleepMin: 450,
            efficiency: 92,
            deepMin: 90,
            remMin: 120,
            lightMin: 240,
            disturbances: 3,
            sleepStart: nil,
            sleepEnd: nil,
            sleepScore: 82,
            restingHR: 52,
            avgHrv: 68,
            recovery: 85,
            recoveryStatus: "high",
            recoveryBand: "green",
            strain: 14.2,
            sleepTargetMin: 480,
            targetStrain: 12.4,
            targetStrainConfidence: "high",
            recentOverload: false,
            adviceSignals: []
        )
    }
}
