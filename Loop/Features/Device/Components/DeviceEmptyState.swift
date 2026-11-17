import SwiftUI

/// No strap in view: the floating band, a line of context, and one action.
struct DeviceEmptyState: View {
    let isScanning: Bool
    var lastSyncText: String? = nil
    let onSearch: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            ZStack {
                DeviceArtwork()

                if isScanning {
                    ProgressView().controlSize(.large)
                }
            }

            VStack(spacing: 8) {
                Text(isScanning ? NSLocalizedString("Recherche du bracelet…", tableName: "Base", comment: "") : NSLocalizedString("Aucun bracelet", tableName: "Base", comment: ""))
                    .font(.system(size: 20, weight: .semibold))
                Text(isScanning
                     ? NSLocalizedString("Garde ton WHOOP à proximité.", tableName: "Base", comment: "")
                     : NSLocalizedString("Connecte ton WHOOP 4.0 pour lire ses données.", tableName: "Base", comment: ""))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let lastSyncText {
                    Text(String(format: NSLocalizedString("device.last_sync", tableName: "Base", comment: ""), lastSyncText))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            searchButton
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    private var searchButton: some View {
        Button(action: onSearch) {
            Text(isScanning ? NSLocalizedString("Recherche en cours…", tableName: "Base", comment: "") : NSLocalizedString("Rechercher le bracelet", tableName: "Base", comment: ""))
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .disabled(isScanning)
    }
}

#Preview("Vide") {
    DeviceEmptyState(isScanning: false, onSearch: {})
        .padding()
}

#Preview("Scan · sombre") {
    DeviceEmptyState(isScanning: true, onSearch: {})
        .padding()
        .preferredColorScheme(.dark)
}
