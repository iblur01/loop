import Foundation

// MARK: - HRVError

/// Error type for HRV metric input validation paths.
///
/// Swift ports of `hrv.py` raise explicit errors when there are too few plausible
/// RR intervals after filtering, matching the Python oracle's `ValueError` behavior.
public enum HRVError: Error, Equatable {
    /// Fewer than two plausible RR intervals remained after range filtering.
    case insufficientPlausibleIntervals(function: String, count: Int)
}
