import Foundation

/// Where the maximum heart rate used for a cardio computation came from.
public enum MaxHeartRateSource: String, Codable, Equatable, Sendable {
    /// User reference (`MaxHeartRateReference`), whatever its own provenance label.
    case personal
    /// 99.5th percentile of pooled heart rate (`estimateHRmax`).
    case estimated
    /// Explicit override (replay `--max-hr`, tests).
    case replay
}

extension MaxHeartRatePolicy {
    /// Same precedence as `fixedValue`: override, then personal reference, otherwise estimate.
    public static func source(override: Double?, personal: MaxHeartRateReference?) -> MaxHeartRateSource {
        if override != nil { return .replay }
        if personal != nil { return .personal }
        return .estimated
    }
}

/// Minutes per Karvonen heart-rate-reserve zone for one computation window (a workout), with
/// the resting and maximum heart rate actually used. Single source for every zone display:
/// built from `StrainResult` with the same bounds as the cardio load (`karvZoneLower`).
public struct HeartRateZoneBreakdown: Codable, Equatable, Sendable {
    /// Minutes in zones 1…5 (index 0 = zone 1, ≥ 50 % HRR). Exactly 5 values.
    public let zoneMinutes: [Double]
    /// Minutes below zone 1 (< 50 % HRR), i.e. zone 0. Measured, never counted as load.
    public let belowZoneMinutes: Double
    public let restingHR: Double
    public let maxHR: Double
    public let maxHRSource: MaxHeartRateSource

    /// Lower bounds of zones 1…5 in % of heart-rate reserve, as used by the cardio load.
    public static var lowerBoundsPercentHRR: [Double] { karvZoneLower }

    /// nil unless the values are a usable breakdown: 5 finite non-negative zones, a positive
    /// reserve and some covered time.
    public init?(zoneMinutes: [Double], belowZoneMinutes: Double, restingHR: Double, maxHR: Double,
                 maxHRSource: MaxHeartRateSource) {
        guard zoneMinutes.count == 5,
              (zoneMinutes + [belowZoneMinutes]).allSatisfy({ $0.isFinite && $0 >= 0 }),
              restingHR.isFinite, maxHR.isFinite, maxHR > restingHR,
              zoneMinutes.reduce(0, +) + belowZoneMinutes > 0 else { return nil }
        self.zoneMinutes = zoneMinutes
        self.belowZoneMinutes = belowZoneMinutes
        self.restingHR = restingHR
        self.maxHR = maxHR
        self.maxHRSource = maxHRSource
    }

    /// Breakdown of a strain computation done with `restingHR` / `maxHR`.
    public init?(result: StrainResult, restingHR: Double, maxHR: Double, maxHRSource: MaxHeartRateSource) {
        self.init(zoneMinutes: result.hrZoneMinutes, belowZoneMinutes: result.belowZoneMinutes,
                  restingHR: restingHR, maxHR: maxHR, maxHRSource: maxHRSource)
    }

    /// Covered minutes (zone 0 included): the supported observation time of the window.
    public var totalMinutes: Double { zoneMinutes.reduce(0, +) + belowZoneMinutes }

    /// Lower bound in bpm of zone `zone` (1…5): resting + % × reserve.
    public func lowerBpm(zone: Int) -> Double? {
        guard (1...5).contains(zone) else { return nil }
        return restingHR + karvZoneLower[zone - 1] / 100 * (maxHR - restingHR)
    }

    /// Zone (0 = below zone 1, 1…5) of a heart rate under the given references, with the
    /// cardio load's bounds. nil for invalid inputs.
    public static func zone(forBpm bpm: Double, restingHR: Double, maxHR: Double) -> Int? {
        guard bpm.isFinite, restingHR.isFinite, maxHR.isFinite, maxHR > restingHR else { return nil }
        let pct = pctHRR(bpm: bpm, restingHR: restingHR, hrReserve: maxHR - restingHR)
        return pct < karvZoneLower[0] ? 0 : zoneIndex(forPctHRR: pct) + 1
    }
}
