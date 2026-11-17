import SwiftUI

/// The only door to the technical layer. A single quiet row — firmware, Bluetooth identity, DB
/// stats, diagnostic and logs all stay behind it (progressive disclosure), never on the main page.
struct DeviceDetailsRow: View {
    let firmware: String?
    let onOpen: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("Détails techniques", tableName: "Base", comment: ""))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                if let firmware {
                    Text("Firmware \(firmware)")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .deviceSurface()
        .pressable(action: onOpen)
    }
}

#Preview {
    DeviceDetailsRow(firmware: "55.1.3.0", onOpen: {})
        .padding()
}
