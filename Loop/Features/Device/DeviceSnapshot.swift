import SwiftUI

/// Presentation model for the Device page. Decouples the SwiftUI views from the live
/// `DeviceConnectionViewModel` / `SyncCoordinator` / `LoopDataRepository` so every component renders
/// in isolation (and previews in all states) from a plain value type.
///
/// Deliberately restrained: the page is monochrome. The *only* colour the model exposes is a single
/// semantic status dot — everything else is ink, material and type.
struct DeviceSnapshot {

    enum Connection {
        case connected
        case connecting
        case scanning
        case disconnected

        var word: String {
            switch self {
            case .connected:    return NSLocalizedString("Connecté", tableName: "Base", comment: "")
            case .connecting:   return NSLocalizedString("Connexion", tableName: "Base", comment: "")
            case .scanning:     return NSLocalizedString("Recherche", tableName: "Base", comment: "")
            case .disconnected: return NSLocalizedString("Déconnecté", tableName: "Base", comment: "")
            }
        }

        var isBusy: Bool { self == .scanning || self == .connecting }
        var isLinked: Bool { self == .connected }
    }

    enum Sync: Equatable {
        case upToDate
        case syncing
        case stuck
        case offline
        case error(String)

        var word: String {
            switch self {
            case .upToDate:     return NSLocalizedString("à jour", tableName: "Base", comment: "")
            case .syncing:      return NSLocalizedString("synchronisation", tableName: "Base", comment: "")
            case .stuck:        return NSLocalizedString("bloqué", tableName: "Base", comment: "")
            case .offline:      return NSLocalizedString("hors ligne", tableName: "Base", comment: "")
            case .error:        return NSLocalizedString("erreur", tableName: "Base", comment: "")
            }
        }
    }

    // MARK: - Stored

    var deviceName: String?
    var connection: Connection
    var sync: Sync
    var batteryPercent: Int?
    var isCharging: Bool
    var isOnWrist: Bool?
    var realtimeHROn: Bool
    var strapNeedsReboot: Bool

    var lastSyncedAt: Date?
    var lastSampleAt: Date?
    var lastComputedAt: Date?

    var firmwareHarvard: String?
    var peripheralUUID: String?

    // MARK: - Derived (restrained)

    /// Whether to show the device layout vs the empty state. Driven by the connection, not just the
    /// advertised name — on a reconnect/state-restoration the strap can be fully connected before
    /// CoreBluetooth resolves `peripheral.name`, which would otherwise flash the "no device" screen.
    var hasDevice: Bool {
        switch connection {
        case .connected, .connecting: return true
        case .scanning, .disconnected: return deviceName != nil
        }
    }

    /// Name to display, with a calm fallback once we know a strap is on the link but unnamed.
    var displayName: String {
        if let deviceName, !deviceName.isEmpty { return deviceName }
        return connection == .disconnected ? NSLocalizedString("Bracelet", tableName: "Base", comment: "") : "WHOOP"
    }

    /// The single accent on the whole page. Calm, semantic, used once (the status dot).
    var statusDot: Color {
        switch connection {
        case .connected:
            if case .stuck = sync { return .orange }
            if case .error = sync { return .orange }
            return .green
        case .connecting, .scanning: return .yellow
        case .disconnected:          return .secondary
        }
    }

    /// One quiet status line, e.g. "Connecté · à jour".
    var statusLine: String {
        switch connection {
        case .connected:    return String(format: NSLocalizedString("device.connected.status", tableName: "Base", comment: ""), sync.word)
        case .connecting:   return NSLocalizedString("Connexion au bracelet…", tableName: "Base", comment: "")
        case .scanning:     return NSLocalizedString("Recherche du bracelet…", tableName: "Base", comment: "")
        case .disconnected: return NSLocalizedString("Déconnecté", tableName: "Base", comment: "")
        }
    }

    var batteryFraction: Double {
        guard let pct = batteryPercent else { return 0 }
        return min(max(Double(pct) / 100, 0), 1)
    }

    var batteryLabel: String {
        guard let pct = batteryPercent else { return "—" }
        return "\(pct) %"
    }

    /// Numerals stay ink unless the level is genuinely low — the one place a warning tint is allowed.
    var batteryEmphasis: Color {
        guard batteryPercent != nil, !isCharging else { return .primary }
        return Metric.batteryState(percent: batteryPercent, isCharging: false) == .poor ? batteryColor : .primary
    }

    /// Battery is a state metric (spec design §2.3): neutral when healthy, fair/poor under the shared
    /// thresholds, good while charging. Unknown level falls back to ink.
    var batteryColor: Color {
        guard batteryPercent != nil else { return .primary.opacity(0.85) }
        return Metric.batteryState(percent: batteryPercent, isCharging: isCharging).color
    }

    var sensorLabel: String {
        switch isOnWrist {
        case .some(true):  return NSLocalizedString("Au poignet", tableName: "Base", comment: "")
        case .some(false): return NSLocalizedString("Retiré", tableName: "Base", comment: "")
        case .none:        return NSLocalizedString("Inconnu", tableName: "Base", comment: "")
        }
    }

    var freshnessLabel: String {
        guard let ref = lastSampleAt ?? lastSyncedAt else { return NSLocalizedString("Aucune", tableName: "Base", comment: "") }
        let age = Date().timeIntervalSince(ref)
        if age < 15 * 60 { return NSLocalizedString("À jour", tableName: "Base", comment: "") }
        if age < 3 * 3600 { return NSLocalizedString("Récentes", tableName: "Base", comment: "") }
        return NSLocalizedString("Anciennes", tableName: "Base", comment: "")
    }

    var lastSyncText: String { relative(lastSyncedAt) ?? NSLocalizedString("Jamais", tableName: "Base", comment: "") }

    private func relative(_ date: Date?) -> String? {
        guard let date else { return nil }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Mock builders (previews)

extension DeviceSnapshot {
    static func mock(
        deviceName: String? = "WHOOP de Théo",
        connection: Connection = .connected,
        sync: Sync = .upToDate,
        batteryPercent: Int? = 78,
        isCharging: Bool = false,
        isOnWrist: Bool? = true,
        realtimeHROn: Bool = false,
        strapNeedsReboot: Bool = false,
        lastSyncedAt: Date? = Date().addingTimeInterval(-4 * 60),
        lastSampleAt: Date? = Date().addingTimeInterval(-3 * 60)
    ) -> DeviceSnapshot {
        DeviceSnapshot(
            deviceName: deviceName,
            connection: connection,
            sync: sync,
            batteryPercent: batteryPercent,
            isCharging: isCharging,
            isOnWrist: isOnWrist,
            realtimeHROn: realtimeHROn,
            strapNeedsReboot: strapNeedsReboot,
            lastSyncedAt: lastSyncedAt,
            lastSampleAt: lastSampleAt,
            lastComputedAt: Date().addingTimeInterval(-2 * 60),
            firmwareHarvard: "55.1.3.0",
            peripheralUUID: "A1B2C3D4-0000-1111-2222-334455667788"
        )
    }
}
