import SwiftUI

/// Quiet hero: the band floats freely (no card), the device name as a large title, and a single
/// status line carrying the page's only accent — a small status dot.
///
/// The product cutout is a black band on transparent — invisible on a dark background — so it sits
/// over an adaptive backlight: a soft light pool in dark mode rims the silhouette, a subtle ground
/// shadow grounds it in light mode.
struct DeviceHero: View {
    let snapshot: DeviceSnapshot

    var body: some View {
        VStack(spacing: 24) {
            DeviceArtwork()
            VStack(spacing: 8) {
                Text(snapshot.displayName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                statusLine
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Status

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(snapshot.statusDot)
                .frame(width: 7, height: 7)

            Text(snapshot.statusLine)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// Shared floating band artwork for both paired and empty device states.
struct DeviceArtwork: View {
    @Environment(\.colorScheme) private var scheme
    private var isDark: Bool { scheme == .dark }

    var body: some View {
        ZStack {
            backlight
            Image("whoop_device")
                .resizable()
                .scaledToFit()
                .frame(height: 210)
                .shadow(color: isDark ? .white.opacity(0.10) : .black.opacity(0.22), radius: 18, y: 10)
        }
        .frame(height: 230)
        .accessibilityHidden(true)
    }

    /// Soft radial pool behind the band. In dark mode it lifts the black silhouette off the
    /// background; in light mode it reads as a faint ground shadow.
    private var backlight: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: isDark
                        ? [.white.opacity(0.16), .white.opacity(0.04), .clear]
                        : [.black.opacity(0.06), .clear],
                    center: .center,
                    startRadius: 4,
                    endRadius: 150
                )
            )
            .frame(width: 300, height: 300)
            .blur(radius: 12)
    }

}

#Preview("Connecté") {
    DeviceHero(snapshot: .mock())
        .padding(24)
}

#Preview("Déconnecté · sombre") {
    DeviceHero(snapshot: .mock(connection: .disconnected, sync: .offline))
        .padding(24)
        .preferredColorScheme(.dark)
}
