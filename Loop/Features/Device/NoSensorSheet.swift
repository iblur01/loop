import SwiftUI

// MARK: - NoSensorSheet

/// Medium-detent sheet shown when no sensor is paired with the app.
/// Walks the user through: missing sensor → pairing-mode check.
/// Uses iOS 26 Liquid Glass surfaces and button styles.
@available(iOS 26.0, *)
struct NoSensorSheet: View {
    /// Triggered when the user confirms the sensor is in pairing mode (step 2).
    var onConnect: () -> Void
    /// Triggered when the user taps "Ignorer".
    var onDismiss: () -> Void

    @State private var step: Step = .noSensor
    @State private var forward: Bool = true

    private enum Step {
        case noSensor
        case pairingCheck
    }

    var body: some View {
        ZStack {
            Group {
                switch step {
                case .noSensor:
                    noSensorStep
                case .pairingCheck:
                    pairingCheckStep
                }
            }
            .transition(slideTransition)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(36)
    }

    // MARK: - Steps

    private var noSensorStep: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            VStack(spacing: 22) {
                sensorBadge
                copyBlock(
                    title: NSLocalizedString("Aucun capteur connecté", tableName: "Base", comment: ""),
                    message: NSLocalizedString("Connectez votre bracelet pour commencer à suivre votre récupération, votre sommeil et votre strain.", tableName: "Base", comment: "")
                )
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .padding(.horizontal, 20)

            Spacer(minLength: 16)

            VStack(spacing: 12) {
                Button {
                    advance(to: .pairingCheck, forward: true)
                } label: {
                    HStack(spacing: 10) {
                        BluetoothLogo(color: .white, size: 18)
                        Text(NSLocalizedString("Connecter un capteur", tableName: "Base", comment: ""))
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
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    private var pairingCheckStep: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    advance(to: .noSensor, forward: false)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(10)
                }
                .buttonStyle(.glass)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer(minLength: 4)

            VStack(spacing: 22) {
                pulsingLEDBadge
                copyBlock(
                    title: NSLocalizedString("Votre capteur est-il en mode association ?", tableName: "Base", comment: ""),
                    message: NSLocalizedString("La LED de votre bracelet doit clignoter en bleu. Sinon, suivez le tuto pour activer ce mode.", tableName: "Base", comment: "")
                )
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            Spacer(minLength: 12)

            VStack(spacing: 12) {
                Button(action: onConnect) {
                    Text(NSLocalizedString("Oui, lancer la recherche", tableName: "Base", comment: ""))
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.glassProminent)
                .tint(Color.accentColor)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Sections

    private var sensorBadge: some View {
        BluetoothLogo(color: Color.accentColor, size: 36)
            .frame(width: 84, height: 84)
            // Opaque dans la sheet en verre : pas de verre sur verre.
            .background(Color.accentColor.opacity(0.14), in: .circle)
    }

    private var pulsingLEDBadge: some View {
        PulsingLED(color: Color.accentColor)
            .frame(width: 84, height: 84)
            // Opaque dans la sheet en verre : pas de verre sur verre.
            .background(Color.accentColor.opacity(0.14), in: .circle)
    }

    private func copyBlock(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 8)
        }
    }

    // MARK: - Step navigation

    private func advance(to next: Step, forward: Bool) {
        self.forward = forward
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            step = next
        }
    }

    private var slideTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }
}

// MARK: - PulsingLED

/// A small dot that pulses to suggest a blinking blue LED on the bracelet.
private struct PulsingLED: View {
    var color: Color
    @State private var animate = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .scaleEffect(animate ? 1.6 : 0.8)
                .opacity(animate ? 0 : 0.8)
                .frame(width: 36, height: 36)

            Circle()
                .fill(color)
                .frame(width: 18, height: 18)
                .shadow(color: color.opacity(0.7), radius: animate ? 10 : 4)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }
}

// MARK: - BluetoothLogo

/// Bluetooth glyph drawn with Canvas — SF Symbols doesn't ship one.
/// Source: https://stackoverflow.com/a/79296982 (CC BY-SA 4.0, Thyselius)
struct BluetoothLogo: View {
    var color: Color
    var size: CGFloat

    var body: some View {
        Canvas { context, size in
            let h = size.height
            let y1 = h * 0.05
            let y2 = h * 0.25

            var path = Path()
            path.move(to: CGPoint(x: y2, y: y2))
            path.addLine(to: CGPoint(x: h - y2, y: h - y2))
            path.addLine(to: CGPoint(x: h / 2, y: h - y1))
            path.addLine(to: CGPoint(x: h / 2, y: y1))
            path.addLine(to: CGPoint(x: h - y2, y: y2))
            path.addLine(to: CGPoint(x: y2, y: h - y2))

            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: max(2, size.height * 0.07), lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Preview

@available(iOS 26.0, *)
#Preview {
    Color(.systemGroupedBackground)
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            NoSensorSheet(
                onConnect: {},
                onDismiss: {}
            )
        }
}
