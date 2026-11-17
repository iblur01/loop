import SwiftUI

/// One prominent action, then quiet text actions. No grid of equal coloured tiles. The primary is a
/// single glass-prominent (iOS 26) / ink-capsule (fallback) button; the rest are plain text.
struct DeviceActions: View {
    let snapshot: DeviceSnapshot
    let onPrimary: () -> Void
    let onToggleHR: () -> Void
    let onDisconnect: () -> Void

    @State private var confirmingDisconnect = false

    var body: some View {
        VStack(spacing: 18) {
            primary

            if snapshot.connection.isLinked {
                HStack(spacing: 28) {
                    textAction(snapshot.realtimeHROn ? NSLocalizedString("Arrêter le direct", tableName: "Base", comment: "") : NSLocalizedString("HR en direct", tableName: "Base", comment: ""), action: onToggleHR)
                    Text("·").foregroundStyle(.tertiary)
                    textAction(NSLocalizedString("Déconnecter", tableName: "Base", comment: "")) { confirmingDisconnect = true }
                }
                .font(.system(size: 14, weight: .medium))
            }
        }
        .confirmationDialog(
            NSLocalizedString("Déconnecter le bracelet ?", tableName: "Base", comment: ""),
            isPresented: $confirmingDisconnect,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("Déconnecter", tableName: "Base", comment: ""), role: .destructive, action: onDisconnect)
            Button(NSLocalizedString("Annuler", tableName: "Base", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("La synchronisation s'arrête jusqu'à la prochaine connexion.", tableName: "Base", comment: ""))
        }
    }

    // MARK: - Primary

    private var primary: some View {
        // Bouton natif en verre : un seul retour au toucher (spec design §5.3 règle 4).
        Button(action: onPrimary) { primaryButton }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .disabled(snapshot.connection.isBusy)
    }

    @ViewBuilder
    private var primaryButton: some View {
        let label = HStack(spacing: 9) {
            if snapshot.connection.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: primarySymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .symbolEffect(.rotate, isActive: snapshot.sync == .syncing)
            }
            Text(primaryTitle)
                .font(.system(size: 16, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)

        label
    }

    private var primaryTitle: String {
        switch snapshot.connection {
        case .connected:    return snapshot.sync == .syncing ? NSLocalizedString("Synchronisation…", tableName: "Base", comment: "") : NSLocalizedString("Synchroniser", tableName: "Base", comment: "")
        case .connecting:   return NSLocalizedString("Connexion…", tableName: "Base", comment: "")
        case .scanning:     return NSLocalizedString("Recherche…", tableName: "Base", comment: "")
        case .disconnected: return NSLocalizedString("Rechercher le bracelet", tableName: "Base", comment: "")
        }
    }

    private var primarySymbol: String {
        snapshot.connection.isLinked ? "arrow.triangle.2.circlepath" : "antenna.radiowaves.left.and.right"
    }

    // MARK: - Secondary

    private func textAction(_ title: String, action: @escaping () -> Void) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .pressable(scale: 0.94, action: action)
    }
}

#Preview {
    VStack(spacing: 40) {
        DeviceActions(snapshot: .mock(), onPrimary: {}, onToggleHR: {}, onDisconnect: {})
        DeviceActions(snapshot: .mock(connection: .disconnected), onPrimary: {}, onToggleHR: {}, onDisconnect: {})
        DeviceActions(snapshot: .mock(connection: .scanning), onPrimary: {}, onToggleHR: {}, onDisconnect: {})
    }
    .padding()
}
