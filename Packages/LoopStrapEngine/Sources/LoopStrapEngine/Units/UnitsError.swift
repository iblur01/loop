import Foundation

// MARK: - UnitsError

/// Error type for units.py ValueError / ZeroDivisionError paths.
///
/// Swift ports of `units.py` raise explicit errors on invalid inputs, matching the Python
/// `raise ValueError` / `raise ZeroDivisionError` semantics. Callers must handle these
/// rather than receiving silent NaN or default values (ASVS V5 input-validation parity).
public enum UnitsError: Error, Equatable {
    /// An operation was called with an empty input array.
    /// Mirrors `units.py: ValueError("Window must contain at least one sample")`.
    case emptyInput

    /// Input arrays have different lengths where they must match.
    /// Mirrors `units.py: ValueError(f"len(reds) != len(irs)")`.
    case lengthMismatch(lhs: Int, rhs: Int)

    /// Division by zero when the IR channel DC mean is zero.
    /// Mirrors `units.py: ZeroDivisionError("IR channel is zero; cannot compute SpO2 ratio")`.
    case divisionByZero

    /// Too few independent samples for the calibration fitter.
    /// Mirrors `units.py: ValueError("Need at least 2 samples to fit")` in `fit_spo2` / `fit_skin_temp`.
    case insufficientData(required: Int, actual: Int)

    /// The calibration fit produced a physiologically invalid result.
    /// Mirrors `units.py: ValueError("Fitted b <= 0 — SpO2 must decrease with R")`.
    case invalidCalibrationResult(reason: String)
}
