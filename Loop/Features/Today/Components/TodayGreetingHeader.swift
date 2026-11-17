import SwiftUI

struct TodayGreetingHeader: View {
    let name: String
    let batteryPercentage: Double?
    let isCharging: Bool
    let isBraceletSyncing: Bool
    /// Recalcul local des métriques en cours (engine.compute), pas un appel serveur.
    let isComputing: Bool
    /// `true` = recalcul COMPLET (toutes les nuits), `false` = incrémental (jours modifiés).
    var isFullRecompute: Bool = false
    /// Progression du recalcul en cours (étape, done, total) — pour afficher un %.
    var computeProgress: (stage: String, completed: Int, total: Int)? = nil
    /// Horodatage du dernier calcul local réussi (cache.updatedAt).
    let lastComputedAt: Date?
    /// Erreur du dernier calcul local, le cas échéant.
    let computeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(greeting) \(name)")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.80)

            HStack(spacing: 8) {
                BatteryPill(
                    percentage: normalizedBatteryPercentage,
                    isCharging: isCharging
                )

                StatusPill(status: status)
            }
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(greeting) \(name)")
        .accessibilityValue(TodayL.format("today.battery.accessibility", batteryAccessibilityText, status.accessibilityText))
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= 18 || hour < 5 ? TodayL.text("today.greeting.evening") : TodayL.text("today.greeting.morning")
    }

    private var normalizedBatteryPercentage: Int? {
        guard let batteryPercentage, batteryPercentage.isFinite else { return nil }
        let percentage = batteryPercentage <= 1 ? batteryPercentage * 100 : batteryPercentage
        return Int(min(max(percentage, 0), 100).rounded())
    }

    private var batteryAccessibilityText: String {
        guard let normalizedBatteryPercentage else { return TodayL.text("today.battery.unknown") }
        return "\(normalizedBatteryPercentage)%"
    }

    private var blueTint: Color { Color(hue: 0.56, saturation: 0.72, brightness: 0.92) }
    private var computeTint: Color { Color(hue: 0.40, saturation: 0.70, brightness: 0.82) }

    /// Pourcentage de progression du recalcul en cours, si connu.
    private var computePercent: Int? {
        guard let p = computeProgress, p.total > 0 else { return nil }
        return Int((Double(p.completed) / Double(p.total) * 100).rounded())
    }

    private var status: HeaderSyncStatus {
        if isBraceletSyncing {
            return HeaderSyncStatus(
                text: TodayL.text("today.status.band.sync"),
                symbolName: "dot.radiowaves.left.and.right",
                tint: blueTint,
                accessibilityText: TodayL.text("today.status.band.sync.accessibility")
            )
        }

        // Recalcul local : on l'AFFICHE désormais (l'utilisateur veut voir l'état du pipeline),
        // en distinguant le recalcul COMPLET (toutes les nuits) de l'incrémental (jours modifiés),
        // avec le % quand il est connu. Les valeurs affichées restent valides pendant le recalcul.
        if isComputing {
            let pctSuffix = computePercent.map { " \($0)%" } ?? "…"
            if lastComputedAt == nil {
                return HeaderSyncStatus(
                    text: TodayL.text("today.status.initial") + pctSuffix,
                    symbolName: "function",
                    tint: computeTint,
                    accessibilityText: TodayL.text("today.status.initial.accessibility")
                )
            }
            if isFullRecompute {
                return HeaderSyncStatus(
                    text: TodayL.text("today.status.full") + pctSuffix,
                    symbolName: "arrow.triangle.2.circlepath",
                    tint: computeTint,
                    accessibilityText: TodayL.text("today.status.full.accessibility")
                )
            }
            return HeaderSyncStatus(
                text: TodayL.text("today.status.update") + pctSuffix,
                symbolName: "arrow.clockwise",
                tint: blueTint,
                accessibilityText: TodayL.text("today.status.update.accessibility")
            )
        }

        if shouldSurfaceComputeError {
            return HeaderSyncStatus(
                text: TodayL.text("today.status.error"),
                symbolName: "exclamationmark.triangle.fill",
                tint: .red,
                accessibilityText: TodayL.text("today.status.error.accessibility")
            )
        }

        guard let lastComputedAt else {
            return HeaderSyncStatus(
                text: TodayL.text("today.status.not.calculated"),
                symbolName: "function",
                tint: .secondary,
                accessibilityText: TodayL.text("today.status.not.calculated.accessibility")
            )
        }

        // État stable : on montre la FRAÎCHEUR pour que ce soit parlant (pas un simple « à jour »).
        let minutes = max(Int(Date().timeIntervalSince(lastComputedAt) / 60), 0)
        if minutes < 15 {
            return HeaderSyncStatus(
                text: minutes < 1 ? TodayL.text("today.status.current") : TodayL.format("today.status.current.minutes", String(minutes)),
                symbolName: "checkmark.circle.fill",
                tint: .green,
                accessibilityText: minutes < 1 ? TodayL.text("today.status.current.accessibility") : TodayL.format("today.status.computed.minutes", String(minutes))
            )
        }

        return HeaderSyncStatus(
            text: TodayL.format("today.status.computed", relativeUpdateText(from: lastComputedAt)),
            symbolName: "clock.fill",
            tint: .orange,
            accessibilityText: TodayL.format("today.status.computed.accessibility", relativeUpdateText(from: lastComputedAt))
        )
    }

    private var shouldSurfaceComputeError: Bool {
        guard computeError != nil else { return false }
        guard let lastComputedAt else { return true }

        // Un échec de calcul transitoire ne doit pas envahir Today quand les données actuelles
        // restent assez fraîches pour être utiles.
        let minutesSinceUpdate = Date().timeIntervalSince(lastComputedAt) / 60
        return minutesSinceUpdate > 90
    }

    private func relativeUpdateText(from date: Date) -> String {
        let minutes = max(Int(Date().timeIntervalSince(date) / 60), 0)
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }
}

private struct BatteryPill: View {
    let percentage: Int?
    let isCharging: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .semibold))

            Text(valueText)
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
        }
        .foregroundStyle(batteryTint)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(batteryTint.opacity(0.10))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(batteryTint.opacity(0.18), lineWidth: 1)
                }
        )
        .accessibilityHidden(true)
    }

    private var valueText: String {
        guard let percentage else { return "--%" }
        return "\(percentage)%"
    }

    private var symbolName: String {
        if isCharging { return "bolt.fill" }

        guard let percentage else { return "battery.0" }
        switch percentage {
        case ..<10: return "battery.0"
        case ..<35: return "battery.25"
        case ..<60: return "battery.50"
        case ..<85: return "battery.75"
        default: return "battery.100"
        }
    }

    private var batteryTint: Color {
        guard let percentage else { return .secondary }
        if percentage <= 5 { return .red }
        if isCharging { return .green }
        if percentage < 20 { return .orange }
        return .secondary
    }
}

private struct StatusPill: View {
    let status: HeaderSyncStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbolName)
                .font(.system(size: 11, weight: .semibold))

            Text(status.text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(backgroundTint)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(status.tint.opacity(0.18), lineWidth: 1)
                }
        )
        .accessibilityHidden(true)
    }

    private var backgroundTint: Color {
        if status.tint == .red { return Color.red.opacity(0.12) }
        return status.tint.opacity(0.10)
    }
}

private struct HeaderSyncStatus {
    let text: String
    let symbolName: String
    let tint: Color
    let accessibilityText: String
}

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            PreviewRow("Serveur a jour") {
                TodayGreetingHeader(
                    name: "Théo",
                    batteryPercentage: 78,
                    isCharging: false,
                    isBraceletSyncing: false,
                    isComputing: false,
                    lastComputedAt: Date(),
                    computeError: nil
                )
            }

            PreviewRow("Bracelet en sync") {
                TodayGreetingHeader(
                    name: "Théo",
                    batteryPercentage: 42,
                    isCharging: true,
                    isBraceletSyncing: true,
                    isComputing: false,
                    lastComputedAt: Date(),
                    computeError: nil
                )
            }

            PreviewRow("Refresh serveur") {
                TodayGreetingHeader(
                    name: "Théo",
                    batteryPercentage: 64,
                    isCharging: false,
                    isBraceletSyncing: false,
                    isComputing: true,
                    lastComputedAt: Date().addingTimeInterval(-420),
                    computeError: nil
                )
            }

            PreviewRow("Erreur serveur masquee si donnees fraiches") {
                TodayGreetingHeader(
                    name: "Théo",
                    batteryPercentage: 58,
                    isCharging: false,
                    isBraceletSyncing: false,
                    isComputing: false,
                    lastComputedAt: Date().addingTimeInterval(-900),
                    computeError: "Server unavailable"
                )
            }

            PreviewRow("Erreur serveur persistante") {
                TodayGreetingHeader(
                    name: "Théo",
                    batteryPercentage: 58,
                    isCharging: false,
                    isBraceletSyncing: false,
                    isComputing: false,
                    lastComputedAt: Date().addingTimeInterval(-7200),
                    computeError: "Server unavailable"
                )
            }

            PreviewRow("Serveur ancien") {
                TodayGreetingHeader(
                    name: "Théo",
                    batteryPercentage: 18,
                    isCharging: false,
                    isBraceletSyncing: false,
                    isComputing: false,
                    lastComputedAt: Date().addingTimeInterval(-5400),
                    computeError: nil
                )
            }

            PreviewRow("Batterie critique") {
                TodayGreetingHeader(
                    name: "Théo",
                    batteryPercentage: 4,
                    isCharging: false,
                    isBraceletSyncing: false,
                    isComputing: false,
                    lastComputedAt: Date(),
                    computeError: nil
                )
            }

            PreviewRow("Etat inconnu") {
                TodayGreetingHeader(
                    name: "Théo",
                    batteryPercentage: nil,
                    isCharging: false,
                    isBraceletSyncing: false,
                    isComputing: false,
                    lastComputedAt: nil,
                    computeError: nil
                )
            }
        }
        .padding()
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}

private struct PreviewRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            content
        }
    }
}
