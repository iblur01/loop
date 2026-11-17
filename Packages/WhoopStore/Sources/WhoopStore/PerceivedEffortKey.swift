import Foundation

extension WorkoutPerceivedEffort {
    /// Stable key under which a session's RPE is stored, shared by the engine (read) and the UI
    /// (entry). Imported session: `external:<HealthKit UUID>`. Band-detected session:
    /// `band:<deviceId>:<startTs>` — exact start, so a later re-detection with a shifted start
    /// no longer finds the entry (it is kept in the table, not deleted).
    public static func workoutKey(externalID: String?, deviceId: String, startTs: Int) -> String {
        if let externalID, !externalID.isEmpty { return "external:\(externalID)" }
        return "band:\(deviceId):\(startTs)"
    }
}
