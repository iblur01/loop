import ActivityKit
import SwiftUI
import WidgetKit

struct BraceletBatteryLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BraceletBatteryActivityAttributes.self) { context in
            // Fond : on NE force PAS de teinte pleine (l'ancienne couleur 0.12 par état rendait mal).
            // `activityBackgroundTint(nil)` laisse le système poser son matériau adaptatif — sur
            // iOS 26 c'est le Liquid Glass, qui s'adapte au fond d'écran et au mode clair/sombre.
            // Le glass vient du système ; on se contente d'un contenu propre par-dessus.
            BraceletBatteryLockScreenView(context: context)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(foregroundTint(for: context.state.kind))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.statusTitle, systemImage: context.state.symbolName)
                        .font(.caption.weight(.semibold))
                }

                DynamicIslandExpandedRegion(.trailing) {
                    // Comme l'écran verrouillé : la batterie en gros n'a de sens que pour les états
                    // batterie. En sync, on la montre en chip discret (ou rien si inconnue).
                    if context.state.kind == .syncing {
                        if context.state.batteryPercentage != nil {
                            Label(context.state.batteryText, systemImage: "battery.50")
                                .font(.caption2.weight(.semibold))
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(context.state.batteryText)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(foregroundTint(for: context.state.kind))
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } compactLeading: {
                Image(systemName: context.state.symbolName)
                    .foregroundStyle(foregroundTint(for: context.state.kind))
            } compactTrailing: {
                // En sync, pas de chiffre batterie dans la pilule (l'icône de sync est en leading) :
                // on évite que la compacte se lise comme un indicateur de batterie.
                if context.state.kind != .syncing {
                    Text(context.state.compactBatteryText)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(foregroundTint(for: context.state.kind))
                }
            } minimal: {
                Image(systemName: context.state.symbolName)
                    .foregroundStyle(foregroundTint(for: context.state.kind))
            }
        }
    }
}

private struct BraceletBatteryLockScreenView: View {
    let context: ActivityViewContext<BraceletBatteryActivityAttributes>

    private var tint: Color { foregroundTint(for: context.state.kind) }

    var body: some View {
        HStack(spacing: 14) {
            // Icône posée sur une pastille en matériau (glass) — la profondeur vient du matériau,
            // pas d'une couleur pleine. Le système pose déjà le fond glass ; ceci ajoute juste le
            // contraste local de l'icône.
            Image(systemName: context.state.symbolName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(tint.opacity(0.25), lineWidth: 1))

            VStack(alignment: .leading, spacing: 3) {
                Text(context.state.statusTitle)
                    .font(.headline)
                    .lineLimit(1)

                Text(context.state.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            // Hero à droite : le gros chiffre n'a de sens QUE pour les états batterie (charge /
            // critique). En SYNC, l'ancien code affichait quand même la batterie en gros — d'où la
            // confusion. Désormais en sync on montre un chip batterie discret (info secondaire),
            // et le focus reste sur le statut/détail de synchronisation au centre.
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(context.state.statusTitle)
        .accessibilityValue(context.state.statusMessage)
    }

    @ViewBuilder
    private var trailing: some View {
        if context.state.kind == .syncing {
            if context.state.batteryPercentage != nil {
                Label(context.state.batteryText, systemImage: "battery.50")
                    .font(.caption.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        } else {
            Text(context.state.batteryText)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
    }
}

private extension BraceletBatteryActivityAttributes.ContentState {
    var statusTitle: String {
        switch kind {
        case .charging:
            return String(localized: "activity.charging")
        case .lowBattery:
            return String(localized: "activity.lowBattery")
        case .syncing:
            return String(localized: "activity.syncing")
        }
    }

    var statusMessage: String {
        switch kind {
        case .charging:
            return String(localized: "activity.charging.description")
        case .lowBattery:
            if isCharging {
                return String(localized: "activity.lowBattery.charging")
            }
            return String(localized: "activity.lowBattery.unplugged")
        case .syncing:
            return syncDetail ?? String(localized: "activity.syncing.description")
        }
    }

    var symbolName: String {
        switch kind {
        case .charging:
            return "bolt.fill"
        case .lowBattery:
            return "exclamationmark.triangle.fill"
        case .syncing:
            return "arrow.triangle.2.circlepath"
        }
    }

    var batteryText: String {
        guard let batteryPercentage else { return "--%" }
        return "\(batteryPercentage)%"
    }

    var compactBatteryText: String {
        guard let batteryPercentage else { return "--" }
        return "\(batteryPercentage)"
    }
}

private func foregroundTint(
    for kind: BraceletBatteryActivityAttributes.Kind
) -> Color {
    switch kind {
    case .charging:
        return .green
    case .lowBattery:
        return .red
    case .syncing:
        return Color(hue: 0.56, saturation: 0.72, brightness: 0.92)
    }
}

// MARK: - Xcode Canvas previews
//
// The `#Preview(as:using:contentStates:)` form renders a Live Activity directly in the Canvas —
// lock-screen banner AND each Dynamic Island presentation — driven by static fixtures, no device
// and no ActivityKit request needed. Iterate on layout/copy/tints here, then ship.

#if DEBUG
extension BraceletBatteryActivityAttributes {
    /// Static attributes fixture (the immutable per-activity payload).
    static var preview: BraceletBatteryActivityAttributes {
        BraceletBatteryActivityAttributes(deviceName: "WHOOP 4.0")
    }
}

extension BraceletBatteryActivityAttributes.ContentState {
    /// Charging, 64%.
    static var charging: BraceletBatteryActivityAttributes.ContentState {
        .init(batteryPercentage: 64, isCharging: true, kind: .charging, updatedAt: .now)
    }

    /// Critical battery (<5%), not yet on the charger.
    static var lowBattery: BraceletBatteryActivityAttributes.ContentState {
        .init(batteryPercentage: 4, isCharging: false, kind: .lowBattery, updatedAt: .now)
    }

    /// Sync/calcul en cours, 64%.
    static var syncing: BraceletBatteryActivityAttributes.ContentState {
        .init(batteryPercentage: 64, isCharging: false, kind: .syncing,
              syncDetail: "Calcul local du sommeil et de la récupération", updatedAt: .now)
    }
}

// Lock-screen banner — cycles through both content states.
#Preview("Lock Screen", as: .content, using: BraceletBatteryActivityAttributes.preview) {
    BraceletBatteryLiveActivityWidget()
} contentStates: {
    BraceletBatteryActivityAttributes.ContentState.charging
    BraceletBatteryActivityAttributes.ContentState.lowBattery
    BraceletBatteryActivityAttributes.ContentState.syncing
}

// Dynamic Island — expanded.
#Preview("Island Expanded", as: .dynamicIsland(.expanded), using: BraceletBatteryActivityAttributes.preview) {
    BraceletBatteryLiveActivityWidget()
} contentStates: {
    BraceletBatteryActivityAttributes.ContentState.charging
    BraceletBatteryActivityAttributes.ContentState.lowBattery
    BraceletBatteryActivityAttributes.ContentState.syncing
}

// Dynamic Island — compact (the pill).
#Preview("Island Compact", as: .dynamicIsland(.compact), using: BraceletBatteryActivityAttributes.preview) {
    BraceletBatteryLiveActivityWidget()
} contentStates: {
    BraceletBatteryActivityAttributes.ContentState.charging
    BraceletBatteryActivityAttributes.ContentState.lowBattery
    BraceletBatteryActivityAttributes.ContentState.syncing
}

// Dynamic Island — minimal (multi-activity dot).
#Preview("Island Minimal", as: .dynamicIsland(.minimal), using: BraceletBatteryActivityAttributes.preview) {
    BraceletBatteryLiveActivityWidget()
} contentStates: {
    BraceletBatteryActivityAttributes.ContentState.charging
    BraceletBatteryActivityAttributes.ContentState.lowBattery
    BraceletBatteryActivityAttributes.ContentState.syncing
}
#endif
