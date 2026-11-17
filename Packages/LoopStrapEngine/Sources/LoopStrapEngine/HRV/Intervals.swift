import Foundation

// MARK: - RR interval preprocessing

/// Minimum plausible RR interval in milliseconds.
public let rrMinMs: Double = 300.0

/// Maximum plausible RR interval in milliseconds.
public let rrMaxMs: Double = 2000.0

/// Minimum beat count used by the later full RR-cleaning pipeline.
public let minBeats: Int = 20

/// Return only physiologically plausible RR intervals, preserving input order.
///
/// Accepts values in the closed interval `300...2000` ms.
public func filterRR(_ rrMs: [Double]) -> [Double] {
    rrMs.filter { rrMinMs <= $0 && $0 <= rrMaxMs }
}

/// Convert RR intervals in milliseconds to synthetic peak sample indices.
///
/// This implements only NeuroKit2's default no-`intervals_time` path used by the
/// Phase 2 oracle fixtures: the first peak is `0.0`, then each cumulative RR
/// interval is scaled by `samplingRate / 1000` and rounded to a sample index.
public func intervalsToPeaks(_ intervalsMs: [Double], samplingRate: Int = 1000) -> [Double] {
    var peaks = [0.0]
    var elapsedMs = 0.0
    let scale = Double(samplingRate) / 1000.0

    for interval in intervalsMs {
        elapsedMs += interval
        peaks.append((elapsedMs * scale).rounded(.toNearestOrEven))
    }

    return peaks
}
