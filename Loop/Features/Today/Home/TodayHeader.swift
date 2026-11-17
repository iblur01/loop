import SwiftUI

/// Slim greeting. Name + one quiet status line (computing / syncing / last update). No big banner,
/// no battery pill — device state lives in its own widget when it actually matters.
struct TodayHeader: View {
    let name: String
    /// When the user browses a past day, show that date instead of a greeting.
    let dayTitle: String?
    let isSyncing: Bool
    let isComputing: Bool
    let computeProgress: Double?
    let lastComputedAt: Date?
    let computeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(dayTitle ?? greeting)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.primary)

            HStack(spacing: 7) {
                if isComputing || isSyncing {
                    ProgressView().controlSize(.mini)
                }
                Text(statusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(computeError != nil ? .red : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 6 ? TodayL.text("today.greeting.night") : hour < 12 ? TodayL.text("today.greeting.morning") : hour < 18 ? TodayL.text("today.greeting.afternoon") : TodayL.text("today.greeting.evening")
        return "\(part), \(name)"
    }

    private var statusText: String {
        if let computeError { return computeError }
        if isComputing {
            if let p = computeProgress, p > 0, p < 1 { return TodayL.format("today.status.computing.percent", String(Int(p * 100))) }
            return TodayL.text("today.status.computing")
        }
        if isSyncing { return String(localized: "today.synchronisation.du.bracelet", table: "Today") }
        guard let lastComputedAt else { return String(localized: "today.en.attente.de.donnees", table: "Today") }
        let age = Date().timeIntervalSince(lastComputedAt)
        // Within the last minute (or a tiny clock skew making it "in 0 sec"), just say up to date.
        if age < 60 { return String(localized: "today.a.jour.a.l.instant", table: "Today") }
        return TodayL.format("today.status.current.relative", Self.relativeFormatter.localizedString(for: lastComputedAt, relativeTo: Date()))
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale.current
        return f
    }()
}

#Preview {
    VStack(spacing: 24) {
        TodayHeader(name: "Théo", dayTitle: nil, isSyncing: false, isComputing: false, computeProgress: nil, lastComputedAt: Date().addingTimeInterval(-300), computeError: nil)
        TodayHeader(name: "Théo", dayTitle: "Mercredi 11 juin", isSyncing: false, isComputing: false, computeProgress: nil, lastComputedAt: nil, computeError: nil)
    }
    .padding()
}
