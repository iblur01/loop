import SwiftUI

/// Secondary facts, grouped in a single quiet surface — not four separate cards. Label left, value
/// right, hairline dividers. No icons, no colour. The kind of calm a Settings group has, but on glass.
struct DeviceInfoGroup: View {
    let snapshot: DeviceSnapshot

    var body: some View {
        VStack(spacing: 0) {
            row(NSLocalizedString("Synchronisation", tableName: "Base", comment: ""), snapshot.lastSyncText)
            divider
            row(NSLocalizedString("Données", tableName: "Base", comment: ""), snapshot.freshnessLabel)
            divider
            row(NSLocalizedString("Capteur", tableName: "Base", comment: ""), snapshot.sensorLabel)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .deviceSurface()
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(height: 48)
    }

    private var divider: some View {
        Rectangle()
            .fill(.primary.opacity(0.06))
            .frame(height: 1)
    }
}

#Preview {
    DeviceInfoGroup(snapshot: .mock())
        .padding()
}
