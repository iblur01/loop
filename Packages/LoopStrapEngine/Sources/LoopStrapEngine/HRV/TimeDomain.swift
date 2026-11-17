import Foundation

// MARK: - Time-domain HRV metrics

/// Root mean square of successive NN-interval differences in milliseconds.
///
/// This function does not filter input. Use `rmssd(_:)` for the range-filtering
/// wrapper that mirrors the Python oracle's public `rmssd` behavior.
public func rmssdMs(_ nnMs: [Double]) -> Double {
    let diffs = diff(nnMs)
    guard !diffs.isEmpty else { return 0.0 }

    let meanSquare = diffs.reduce(0.0) { partial, value in
        partial + value * value
    } / Double(diffs.count)
    return meanSquare.squareRoot()
}

/// Compute RMSSD after RR physiological range filtering.
///
/// Throws when fewer than two plausible intervals remain after filtering.
public func rmssd(_ rrMs: [Double]) throws -> Double {
    let nn = filterRR(rrMs)
    guard nn.count >= 2 else {
        throw HRVError.insufficientPlausibleIntervals(function: "rmssd", count: nn.count)
    }
    return rmssdMs(nn)
}

/// Compute SDNN after RR physiological range filtering.
///
/// Delegates to `std(_:)`, which is sample standard deviation (`ddof=1`).
public func sdnn(_ rrMs: [Double]) throws -> Double {
    let nn = filterRR(rrMs)
    guard nn.count >= 2 else {
        throw HRVError.insufficientPlausibleIntervals(function: "sdnn", count: nn.count)
    }
    return try std(nn)
}

/// Compute pNN50 as the percent of successive NN differences greater than 50 ms.
///
/// The denominator is the number of successive differences, matching the project
/// Python oracle's `nightly_hrv` QC metric.
public func pnn50(_ rrMs: [Double]) -> Double {
    let nn = filterRR(rrMs)
    let diffs = diff(nn).map { abs($0) }
    guard !diffs.isEmpty else { return .nan }

    let overThreshold = diffs.filter { $0 > 50.0 }.count
    return Double(overThreshold) / Double(diffs.count) * 100.0
}
