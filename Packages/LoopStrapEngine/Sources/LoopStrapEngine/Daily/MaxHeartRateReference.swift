import Foundation

/// Personal maximum heart rate supplied by the caller (user entry), with its provenance.
/// The engine never reads preferences itself: the app resolves the value and passes it in.
/// `provenance` is an opaque label ("manual", "measured", "ageEstimate"...) used for
/// traceability and cache invalidation only; it does not change the computation.
public struct MaxHeartRateReference: Equatable, Sendable, Codable {
    public let bpm: Double
    public let provenance: String

    /// nil when `bpm` is not finite or outside the technical input range, or provenance is empty.
    public init?(bpm: Double, provenance: String) {
        let label = provenance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bpm.isFinite, CardioInputPolicy.heartRateBPM.contains(bpm), !label.isEmpty else { return nil }
        self.bpm = bpm
        self.provenance = label
    }
}

/// Precedence of the HRmax used by the cardio load: explicit override (replay, tests) first,
/// then the personal reference, otherwise `nil` (the caller keeps its percentile estimate).
public enum MaxHeartRatePolicy {
    public static func fixedValue(override: Double?, personal: MaxHeartRateReference?) -> Double? {
        override ?? personal?.bpm
    }

    /// Cache-key component. Unchanged ("estimated" / raw override) when no personal value is
    /// set, so existing caches stay valid; a personal value or a provenance change invalidates.
    public static func cacheKeyComponent(override: Double?, personal: MaxHeartRateReference?) -> String {
        if let override { return String(override) }
        if let personal { return "personal:\(String(personal.bpm)):\(personal.provenance)" }
        return "estimated"
    }
}
