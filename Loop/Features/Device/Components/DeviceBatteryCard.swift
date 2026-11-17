import SwiftUI

/// The one foregrounded metric: battery. A label, the percentage, and a thin ink bar — monochrome,
/// no colour unless the charge is genuinely low. Charging shows a small bolt, not a green wash.
struct DeviceBatteryCard: View {
    let snapshot: DeviceSnapshot

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(NSLocalizedString("Batterie", tableName: "Base", comment: ""))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 5) {
                    if snapshot.isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .symbolEffect(.pulse, isActive: snapshot.isCharging)
                    }
                    Text(snapshot.batteryLabel)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(snapshot.batteryEmphasis)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: snapshot.batteryFraction))
                }
            }

            bar
        }
        .padding(18)
        .deviceSurface()
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { appeared = true } }
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.08))
                Capsule()
                    .fill(snapshot.batteryColor)
                    .frame(width: geo.size.width * (appeared ? snapshot.batteryFraction : 0))
                    .animation(.spring(response: 0.6, dampingFraction: 0.85), value: snapshot.batteryFraction)
                    .animation(.easeInOut(duration: 0.4), value: snapshot.batteryColor)
            }
        }
        .frame(height: 6)
    }
}

#Preview {
    VStack(spacing: 16) {
        DeviceBatteryCard(snapshot: .mock())
        DeviceBatteryCard(snapshot: .mock(batteryPercent: 14, isCharging: true))
        DeviceBatteryCard(snapshot: .mock(batteryPercent: nil))
    }
    .padding()
}
