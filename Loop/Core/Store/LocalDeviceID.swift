import Foundation

// MARK: - LocalDeviceID

/// Stable local identifier for this user's single WHOOP strap. Replaces the server-bundled
/// `LOOP_DEVICE_ID` config: Loop is offline-first and single-user, so the device id is a purely
/// local, durable key under which decoded rows are stored and queried.
///
/// Persisted in `UserDefaults` so it survives launches. The fallback constant matches the id under
/// which existing local rows were inserted (former bundled `theo-whoop`), so the cutover keeps every
/// previously-offloaded row addressable without a reassign.
enum LocalDeviceID {
    /// UserDefaults key holding the resolved local device id.
    static let defaultsKey = "loopDeviceID"

    /// Fallback id used when none has been persisted yet. Matches the pre-cutover bundled id so
    /// historical rows stay under the same key.
    static let fallback = "theo-whoop"

    /// The current stable local device id, persisting the fallback on first access so it never drifts.
    static var current: String {
        if let stored = UserDefaults.standard.string(forKey: defaultsKey), !stored.isEmpty {
            return stored
        }
        UserDefaults.standard.set(fallback, forKey: defaultsKey)
        return fallback
    }

    /// Override the local device id (e.g. from a future settings screen). Empty values are ignored.
    static func set(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: defaultsKey)
    }
}
