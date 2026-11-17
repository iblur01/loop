import Foundation
import Combine

// MARK: - SyncCoordinator

/// Calcule le `SyncStatus` user-facing (lien BLE + offload historique + watchdog). Offline-first :
/// le leg B (upload serveur) et les legs C/D (pull serveur / refresh via serveur) ont été retirés —
/// il ne reste que la lecture d'état alimentée par les signaux du leg A (offload BLE). La sauvegarde
/// iCloud a son propre statut (`ICloudBackupCoordinator`), volontairement séparé de l'état bracelet.
///
/// `@MainActor` : tous les signaux et le recalcul du status sont sérialisés sur le main actor.
@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var status: SyncStatus = .offline

    // MARK: - État BLE / watchdog (signaux externes)

    private var connected = false
    private var bonded = false
    private var offloadActive = false
    private var strapStuck = false

    /// Message d'erreur courant, prioritaire dans le status. On n'émet `.error` que si une source
    /// le set explicitement, jamais inventé.
    private var errorMessage: String?

    // MARK: - Entrées publiques (signaux du leg A)

    /// Signal du leg BLE (connexion/bonding) vers le coordinator.
    func noteBLELinkChanged(connected: Bool, bonded: Bool) {
        self.connected = connected
        self.bonded = bonded
        recomputeStatus()
    }

    /// Signal du leg A (offload historique) vers le coordinator.
    func noteOffload(active: Bool) {
        offloadActive = active
        recomputeStatus()
    }

    /// Signal du watchdog : bracelet en retard + frontier gelé.
    func noteStrapStuck(_ stuck: Bool) {
        strapStuck = stuck
        recomputeStatus()
    }

    /// Set (ou efface) un message d'erreur prioritaire dans le status.
    func noteError(_ message: String?) {
        errorMessage = message
        recomputeStatus()
    }

    // MARK: - Calcul du status

    /// Recalcule `status` selon un ordre de priorité STRICT (du plus fort au plus faible) :
    /// erreur > anomalie matérielle > offload en cours > idle bonded > offline.
    private func recomputeStatus() {
        let newStatus: SyncStatus

        if let errorMessage {
            newStatus = .error(errorMessage)
        } else if strapStuck {
            newStatus = .strapStuck
        } else if offloadActive {
            newStatus = .syncing(.fromStrap)
        } else if bonded {
            newStatus = .connectedIdle
        } else {
            newStatus = .offline
        }

        if newStatus != status {
            status = newStatus
        }
    }
}
