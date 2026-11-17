import SwiftUI

// MARK: - SensorDetectedSheet

/// Medium-detent sheet shown when a sensor was found during BLE scan.
/// Displays its name, model and battery level, and offers connect / dismiss.
@available(iOS 26.0, *)
struct SensorDetectedSheet: View {
    /// User-visible device name, e.g. "WHOOP de Théo".
    var deviceName: String
    /// Hardware model, e.g. "WHOOP 4.0".
    var model: String
    /// Battery level in 0...1.
    var batteryLevel: Double

    /// Triggered when the user taps "Se connecter".
    var onConnect: () -> Void
    /// Triggered when the user taps "Ignorer".
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Spacer(minLength: 12)

                VStack(spacing: 22) {
                    sensorBadge
                    copyBlock
                    statRow
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .padding(.horizontal, 20)

                Spacer(minLength: 16)

                actionStack
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(36)
    }

    // MARK: - Sections

    private var sensorBadge: some View {
        ZStack(alignment: .bottomTrailing) {
            BluetoothLogo(color: Color.accentColor, size: 36)
                .frame(width: 84, height: 84)
                // Opaque dans la sheet en verre : pas de verre sur verre.
                .background(Color.accentColor.opacity(0.14), in: .circle)

            Circle()
                .fill(Color.green)
                .frame(width: 16, height: 16)
                .overlay(
                    Circle()
                        .stroke(Color(.systemBackground), lineWidth: 2)
                )
                .offset(x: 2, y: 2)
        }
    }

    private var copyBlock: some View {
        VStack(spacing: 6) {
            Text(NSLocalizedString("Capteur détecté", tableName: "Base", comment: ""))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
                .textCase(.uppercase)
                .tracking(0.8)

            Text(deviceName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
    }

    private var statRow: some View {
        HStack(spacing: 10) {
            statChip(
                icon: AnyView(
                    Image(systemName: "applewatch")
                        .font(.system(size: 13, weight: .semibold))
                ),
                label: model,
                tint: Color.accentColor
            )

            statChip(
                icon: AnyView(
                    Image(systemName: batterySymbol)
                        .font(.system(size: 13, weight: .semibold))
                ),
                label: String(format: NSLocalizedString("device.battery", tableName: "Base", comment: ""), String(Int((batteryLevel * 100).rounded()))),
                tint: batteryTint
            )
        }
    }

    private func statChip(icon: AnyView, label: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            icon
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.14), in: .capsule)
    }

    private var actionStack: some View {
        VStack(spacing: 12) {
            Button(action: onConnect) {
                HStack(spacing: 10) {
                    BluetoothLogo(color: .white, size: 18)
                    Text(NSLocalizedString("Se connecter", tableName: "Base", comment: ""))
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.glassProminent)
            .tint(Color.accentColor)

            Button(action: onDismiss) {
                Text(NSLocalizedString("Ignorer", tableName: "Base", comment: ""))
                    .font(.system(size: 16, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.glass)
        }
    }

    // MARK: - Battery helpers

    private var batterySymbol: String {
        switch batteryLevel {
        case ..<0.1: return "battery.0"
        case ..<0.35: return "battery.25"
        case ..<0.6: return "battery.50"
        case ..<0.85: return "battery.75"
        default: return "battery.100"
        }
    }

    private var batteryTint: Color {
        switch batteryLevel {
        case ..<0.15: return .red
        case ..<0.35: return .orange
        default: return .green
        }
    }
}

// MARK: - Preview

@available(iOS 26.0, *)
#Preview {
    Color(.systemGroupedBackground)
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            SensorDetectedSheet(
                deviceName: "WHOOP de Théo",
                model: "WHOOP 4.0",
                batteryLevel: 0.78,
                onConnect: {},
                onDismiss: {}
            )
        }
}
