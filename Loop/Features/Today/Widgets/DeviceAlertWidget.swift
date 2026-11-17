import SwiftUI

/// Device widget that only appears when it matters: a critically low strap, or a charging strap.
/// One small status dot carries the meaning; the rest stays monochrome.
struct DeviceAlertWidget: View {
    let batteryPercent: Double?
    let isCharging: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(dot)
                .frame(width: 24)
                .symbolEffect(.pulse, isActive: isCharging)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
        }
        .widgetSurface()
    }

    private var percentInt: Int? { batteryPercent.map { Int($0.rounded()) } }

    private var symbol: String {
        isCharging ? "bolt.fill" : "battery.25"
    }

    private var dot: Color { isCharging ? Pop.green : Pop.red }

    private var title: String {
        if isCharging { return String(localized: "today.bracelet.en.charge", table: "Today") }
        return String(localized: "today.batterie.faible", table: "Today")
    }

    private var message: String {
        let pct = percentInt.map { "\($0) % · " } ?? ""
        if isCharging { return TodayL.format("today.battery.charging.detail", pct) }
        return TodayL.format("today.battery.low.detail", pct)
    }
}

#Preview {
    VStack(spacing: 14) {
        DeviceAlertWidget(batteryPercent: 9, isCharging: false)
        DeviceAlertWidget(batteryPercent: 64, isCharging: true)
    }
    .padding()
}
