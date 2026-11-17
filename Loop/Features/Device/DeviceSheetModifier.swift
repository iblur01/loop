import SwiftUI

// MARK: - DeviceSheetModifier

/// Presents the device-pairing sheets based on `connection.phase`, with an iOS 17-26
/// availability split: iOS 26+ gets the Liquid Glass `NoSensorSheet`/`SensorDetectedSheet`,
/// earlier versions fall back to minimal `Text` + `Button` sheets wired to the same intents.
///
/// Applied at the `MainTabView` root (not `DeviceView`) so the pairing flow can surface
/// regardless of which tab is currently active.
struct DeviceSheetModifier: ViewModifier {
    @ObservedObject var connection: DeviceConnectionViewModel

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .sheet(isPresented: isNoSensorPresented) {
                    NoSensorSheet(
                        onConnect: { connection.confirmPairing() },
                        onDismiss: { connection.snoozeNoSensorSheet() }
                    )
                }
                .sheet(isPresented: isDetectedPresented) {
                    if case .detected(let name, let model, let batteryLevel) = connection.phase {
                        SensorDetectedSheet(
                            deviceName: name,
                            model: model,
                            batteryLevel: batteryLevel,
                            onConnect: { connection.connectToDetectedDevice() },
                            onDismiss: { connection.dismiss() }
                        )
                    }
                }
        } else {
            content
                .sheet(isPresented: isNoSensorPresented) {
                    fallbackNoSensorSheet
                }
                .sheet(isPresented: isDetectedPresented) {
                    fallbackDetectedSheet
                }
        }
    }

    // MARK: - Fallback sheets (iOS < 26)

    private var fallbackNoSensorSheet: some View {
        VStack(spacing: 16) {
            Text(NSLocalizedString("Aucun capteur connecté", tableName: "Base", comment: ""))
                .font(.headline)
            Text(NSLocalizedString("Connectez votre bracelet pour commencer à suivre votre récupération, votre sommeil et votre strain.", tableName: "Base", comment: ""))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(NSLocalizedString("Connecter un capteur", tableName: "Base", comment: "")) {
                connection.confirmPairing()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .presentationDetents([.medium])
    }

    private var fallbackDetectedSheet: some View {
        Group {
            if case .detected(let name, let model, let batteryLevel) = connection.phase {
                VStack(spacing: 16) {
                    Text(NSLocalizedString("Capteur détecté", tableName: "Base", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(name)
                        .font(.headline)
                    Text(String(format: NSLocalizedString("device.detected.model_battery", tableName: "Base", comment: ""), model, String(Int((batteryLevel * 100).rounded()))))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(NSLocalizedString("Se connecter", tableName: "Base", comment: "")) {
                        connection.connectToDetectedDevice()
                    }
                    .buttonStyle(.borderedProminent)
                    Button(NSLocalizedString("Ignorer", tableName: "Base", comment: "")) {
                        connection.dismiss()
                    }
                }
                .padding(24)
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Bindings

    private var isNoSensorPresented: Binding<Bool> {
        Binding(
            // Stay closed while snoozed, even though the phase is still `.noSensor` — otherwise the
            // sheet re-presents immediately after each dismiss ("Plus tard" loop). Also gated by
            // `noSensorReady` (a few-second debounce) so it doesn't flash at launch before a
            // bracelet has had time to connect.
            get: { connection.phase == .noSensor && connection.noSensorReady && !connection.noSensorSnoozed },
            // Swipe-to-dismiss also snoozes, so it doesn't pop straight back up.
            set: { if !$0 { connection.snoozeNoSensorSheet() } }
        )
    }

    private var isDetectedPresented: Binding<Bool> {
        Binding(
            get: {
                if case .detected = connection.phase { return true }
                return false
            },
            // Don't tear down the connection here: this setter also fires when the sheet
            // auto-dismisses because `phase` advanced past `.detected` to `.bonding`/`.connected`
            // (a successful connect), and calling `dismiss()` then would immediately disconnect
            // the device we just bonded with. Explicit user cancellation goes through the
            // sheet's own "Ignorer" button (`onDismiss: { connection.dismiss() }`).
            set: { _ in }
        )
    }
}
