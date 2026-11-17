import Foundation

// MARK: - NumericError

/// Shared error type for all NumericKit functions.
///
/// Mirrors the explicit `raise` semantics of the Python oracle (`units.py`):
/// empty-input and underdetermined paths are hard errors, not silent NaN/0.
/// This matches ASVS V5 input-validation parity.
public enum NumericError: Error, Equatable {
    /// An operation was called with an empty input array.
    case emptyInput
    /// A least-squares or polynomial fit has fewer observations than parameters.
    case underdeterminedSystem
    /// The normal-equations matrix `XᵗX` is numerically singular (pivot < 1e-12).
    case singularMatrix
}

// MARK: - Statistics

/// Swift port of `np.mean`.
///
/// Returns the arithmetic mean of `xs`.
/// Throws `NumericError.emptyInput` on empty input.
public func mean(_ xs: [Double]) throws -> Double {
    guard !xs.isEmpty else { throw NumericError.emptyInput }
    return xs.reduce(0, +) / Double(xs.count)
}

/// Swift port of `np.std(xs, ddof=1)` — sample standard deviation.
///
/// Returns the sample standard deviation (divide by `n-1`, matching numpy's `ddof=1`).
/// Returns `0.0` for a single-element array (no deviation possible).
/// Throws `NumericError.emptyInput` on empty input.
public func std(_ xs: [Double]) throws -> Double {
    guard !xs.isEmpty else { throw NumericError.emptyInput }
    guard xs.count > 1 else { return 0.0 }
    let m = xs.reduce(0, +) / Double(xs.count)
    let sumSq = xs.reduce(0.0) { $0 + ($1 - m) * ($1 - m) }
    return (sumSq / Double(xs.count - 1)).squareRoot()
}

/// Swift port of `np.median`.
///
/// Returns the median of `values`:
/// - Odd-N: the single middle element of the sorted array.
/// - Even-N: the average of the two middle elements of the sorted array (numpy Pattern 5 —
///   identical to linear interpolation at q=50).
///
/// Throws `NumericError.emptyInput` on empty input.
public func median(_ values: [Double]) throws -> Double {
    guard !values.isEmpty else { throw NumericError.emptyInput }
    let sorted = values.sorted()
    let n = sorted.count
    if n % 2 == 1 {
        return sorted[n / 2]
    } else {
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }
}

/// Swift port of `np.percentile(values, q)` with default `method="linear"`.
///
/// Computes the q-th percentile of `values` using linear interpolation between
/// adjacent ranks (numpy's default interpolation method, unchanged since 1.22).
///
/// Algorithm (Pattern 1 from RESEARCH.md):
/// ```
/// rank = (q / 100) * (n - 1)
/// lower = floor(rank); upper = ceil(rank); fraction = rank - lower
/// result = sorted[lower] + fraction * (sorted[upper] - sorted[lower])
/// ```
///
/// - Parameters:
///   - values: Input array (unsorted is fine — sorted internally).
///   - q: Percentile in [0, 100].
/// - Returns: The q-th percentile.
/// - Throws: `NumericError.emptyInput` on empty input.
public func percentile(_ values: [Double], _ q: Double) throws -> Double {
    guard !values.isEmpty else { throw NumericError.emptyInput }
    let sorted = values.sorted()
    let n = sorted.count
    if n == 1 { return sorted[0] }
    // Clamp rank to [0, n-1] to match numpy's implicit clamp behavior for q outside [0, 100].
    let rawRank = (q / 100.0) * Double(n - 1)
    let rank = max(0.0, min(Double(n - 1), rawRank))
    let lower = Int(rank.rounded(.down))
    let upper = Int(rank.rounded(.up))
    if lower == upper { return sorted[lower] }
    let fraction = rank - Double(lower)
    return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
}

// MARK: - Helpers

/// Median absolute deviation: `median(|x - median(x)|)`.
///
/// Internal helper for `_robustSpread`. Callers guarantee non-empty input.
func _mad(_ xs: [Double]) -> Double {
    // Non-throwing: callers guarantee non-empty input upstream.
    let m = (try? median(xs)) ?? 0.0
    let deviations = xs.map { abs($0 - m) }
    return (try? median(deviations)) ?? 0.0
}

/// Robust spread estimator: `1.4826 * MAD` (or IQR fallback when MAD == 0).
///
/// Used by `Units/SpO2.swift` (Plan 06) to compute robust windows, mirroring
/// `units.py`'s `_robust_spread`. Returns `0.0` for fewer than 2 elements.
func _robustSpread(_ xs: [Double]) -> Double {
    guard xs.count >= 2 else { return 0.0 }
    let mad = _mad(xs)
    if mad > 0 {
        return 1.4826 * mad
    }
    // IQR fallback: percentile(75) - percentile(25)
    let p75 = (try? percentile(xs, 75.0)) ?? 0.0
    let p25 = (try? percentile(xs, 25.0)) ?? 0.0
    return p75 - p25
}
