import Foundation

// MARK: - PeakFinding

/// Result of `findPeaks`. Contains the 0-based indices of detected peaks in the input array.
public struct PeakResult {
    /// 0-based indices of detected peaks in the input array, sorted ascending.
    public let indices: [Int]
}

/// Swift port of `scipy.signal.find_peaks(x, distance=, height=)`.
/// Implements the subset of scipy's `find_peaks` used by `hrv.py` and `sleep_features.py`:
/// local maximum detection (strict), optional minimum height threshold, and optional
/// minimum horizontal distance between peaks (greedy highest-first assignment).
///
/// - Parameters:
///   - x: 1-D signal array.
///   - distance: Minimum number of indices between any two accepted peaks (inclusive bound).
///     Greedy highest-first assignment matches scipy's priority when peaks are equidistant.
///   - height: Minimum height threshold (inclusive). Only peaks where `x[i] >= height` are kept.
/// - Returns: `PeakResult` with sorted peak indices. Returns empty result for empty or singleton input.
///   Does NOT throw — matches scipy's contract where edge cases return empty arrays.
public func findPeaks(
    _ x: [Double],
    distance: Int? = nil,
    height: Double? = nil
) -> PeakResult {
    guard x.count >= 3 else { return PeakResult(indices: []) }

    // Step 1: Collect local maxima (strict: x[i] > x[i-1] AND x[i] > x[i+1])
    var candidates: [Int] = []
    for i in 1..<(x.count - 1) {
        if x[i] > x[i - 1] && x[i] > x[i + 1] {
            candidates.append(i)
        }
    }

    // Step 2: Height filter — keep only peaks where x[peak] >= height
    if let h = height {
        candidates = candidates.filter { x[$0] >= h }
    }

    // Step 3: Distance filter — greedy highest-first assignment.
    // Sort candidates by height descending; greedily keep from tallest,
    // suppressing any un-assigned peak within `distance` indices of a kept peak.
    // Greedy highest-first matches scipy's priority when peaks are equidistant.
    if let dist = distance, candidates.count > 1 {
        let sorted = candidates.sorted { x[$0] > x[$1] }
        var kept = [Int]()
        for idx in sorted {
            let tooClose = kept.contains { abs($0 - idx) < dist }
            if !tooClose {
                kept.append(idx)
            }
        }
        candidates = kept.sorted()
    }

    return PeakResult(indices: candidates)
}
