import Foundation

// MARK: - SyncStatus

/// User-facing state of the bracelet link + historical offload. Offline-first: there is no server
/// leg anymore (iCloud backup has its own status — see `ICloudBackupCoordinator`), so the only
/// "syncing" phase is the BLE historical offload from the strap.
enum SyncStatus: Equatable {
    case offline                    // BLE déconnecté
    case connectedIdle              // bonded, rien en cours
    case syncing(SyncPhase)         // offload historique en cours
    case strapStuck                 // watchdog : bracelet en retard + frontier gelé
    case error(String)
}

// MARK: - SyncPhase

enum SyncPhase: Equatable {
    case fromStrap                  // offload historique (couche A)
}
