import Foundation

// MARK: - SpO2Fit

/// Result of a `fitSpo2` calibration fit.
///
/// Provides the intercept `a` and slope `b` for the empirical formula SpO2 = a − b·R.
public struct SpO2Fit {
    /// Fitted intercept (SpO2 at R = 0).
    public let a: Double
    /// Fitted slope (coefficient of R; must be positive for physiologically valid SpO2).
    public let b: Double

    public init(a: Double, b: Double) {
        self.a = a
        self.b = b
    }
}

// MARK: - fitSpo2

/// Fit SpO2 = a − b·R to WHOOP-reported SpO2 values via ordinary least squares.
///
/// Mirrors `units.py: fit_spo2(R_values, whoop_spo2, quadratic)`.
///
/// Builds a design matrix [1, R] (linear) or [R², R, 1] (quadratic) and delegates
/// to `leastSquares()`. The returned `SpO2Fit` has `a` = intercept and `b` = slope.
///
/// - Parameters:
///   - R: Per-sample ratio-of-ratios from `spo2FeatureWindow`.
///   - spo2: Corresponding WHOOP-reported SpO2 (%), aligned per sample.
///   - quadratic: If true, fit SpO2 = a·R² + b·R + c (3 params); returns (c, -b_q)
///                matching the linear convention. Default false.
/// - Returns: `SpO2Fit` with fitted `a` and `b` values.
/// - Throws: `NumericError.emptyInput` if R or spo2 is empty;
///           `NumericError.underdeterminedSystem` if n < required columns.
public func fitSpo2(R: [Double], spo2: [Double], quadratic: Bool = false) throws -> SpO2Fit {
    guard !R.isEmpty && !spo2.isEmpty else { throw NumericError.emptyInput }
    guard R.count == spo2.count else { throw NumericError.underdeterminedSystem }
    // units.py raises ValueError("Need at least 2 samples to fit")
    guard R.count >= 2 else { throw UnitsError.insufficientData(required: 2, actual: R.count) }

    let aRet: Double
    let bRet: Double

    if quadratic {
        // Quadratic: X = [R², R, 1] → SpO2 = a_q·R² + b_q·R + c_q
        // Returns (c_q, -b_q) to match the linear (a, b) convention
        let X: [[Double]] = R.map { r in [r * r, r, 1.0] }
        let coeffs = try leastSquares(X: X, y: spo2)
        let bQ = coeffs[1]
        let cQ = coeffs[2]
        // Consistent with Python: return (c, -b_q)
        aRet = cQ
        bRet = -bQ
    } else {
        // Linear: X = [1, R] → SpO2 = β₀ + β₁·R; a = β₀, b = −β₁
        let X: [[Double]] = R.map { r in [1.0, r] }
        let coeffs = try leastSquares(X: X, y: spo2)
        aRet = coeffs[0]
        bRet = -coeffs[1]   // negate: SpO2 = a − b·R
    }

    // units.py: raise ValueError if b <= 0 (SpO2 must decrease with R)
    guard bRet > 0.0 else {
        throw UnitsError.invalidCalibrationResult(
            reason: "Fitted b <= 0 (\(bRet)) — SpO2 must decrease with R"
        )
    }

    return SpO2Fit(a: aRet, b: bRet)
}

// MARK: - SkinTempFit

/// Result of a `fitSkinTemp` calibration fit.
///
/// Provides slope and offset for: T = slope * raw + offset.
public struct SkinTempFit {
    /// Fitted slope in °C per ADC count.
    public let slope: Double
    /// Fitted offset in °C. Exactly 0.0 when `fitOffset == false` (see RESEARCH.md Pitfall 3).
    public let offset: Double

    public init(slope: Double, offset: Double) {
        self.slope = slope
        self.offset = offset
    }
}

// MARK: - fitSkinTemp

/// Fit T_°C = slope * raw + offset to WHOOP skin-temperature data.
///
/// Mirrors `units.py: fit_skin_temp(raw_values, whoop_celsius, fit_offset)`.
///
/// For deviation calibration (recommended), pass nightly Δraw and WHOOP nightly deviation,
/// and set `fitOffset = false` (forces intercept = 0.0 exactly via closed form).
///
/// IMPORTANT: The two code paths (fitOffset true/false) are intentionally separate:
/// - `fitOffset = true`: 2-column OLS via `leastSquares([[raw, 1.0], ...], y)` → slope, offset
/// - `fitOffset = false`: `slope = dot(raw, y) / dot(raw, raw)`, `offset = 0.0` EXACTLY
///
/// See RESEARCH.md Pitfall 3 — the closed-form path avoids floating-point drift
/// from degenerate 1-column lstsq.
///
/// - Parameters:
///   - raw: Raw ADC counts (nightly means or per-sample).
///   - y:   Corresponding WHOOP-reported temperature in °C.
///   - fitOffset: If true, fit both slope and offset. If false, force offset = 0.0.
/// - Returns: `SkinTempFit` with fitted slope and offset.
/// - Throws: `NumericError.emptyInput` if arrays are empty.
public func fitSkinTemp(raw: [Double], y: [Double], fitOffset: Bool = true) throws -> SkinTempFit {
    guard !raw.isEmpty && !y.isEmpty else { throw NumericError.emptyInput }
    guard raw.count == y.count else { throw NumericError.underdeterminedSystem }
    // units.py raises ValueError("Need at least 2 samples to fit")
    guard raw.count >= 2 else { throw UnitsError.insufficientData(required: 2, actual: raw.count) }

    if fitOffset {
        // 2-column OLS: X = [[raw[i], 1.0], ...]
        let X: [[Double]] = raw.map { r in [r, 1.0] }
        let coeffs = try leastSquares(X: X, y: y)
        return SkinTempFit(slope: coeffs[0], offset: coeffs[1])
    } else {
        // Closed-form offset=0 path: slope = dot(raw, y) / dot(raw, raw)
        // This path MUST remain separate — using lstsq with a 1-column matrix would
        // yield offset ≈ 1e-16 instead of exactly 0.0 (RESEARCH.md Pitfall 3).
        var dotRawY = 0.0
        var dotRawRaw = 0.0
        for i in 0..<raw.count {
            dotRawY    += raw[i] * y[i]
            dotRawRaw  += raw[i] * raw[i]
        }
        guard dotRawRaw > 0.0 else { throw NumericError.singularMatrix }
        let slope = dotRawY / dotRawRaw
        let offset = 0.0   // exactly 0.0, not computed — see RESEARCH.md Pitfall 3
        return SkinTempFit(slope: slope, offset: offset)
    }
}

// MARK: - LeaveOneNightOutResult

/// Summary result of `leaveOneNightOut` cross-validation.
public struct LeaveOneNightOutResult {
    /// Per-night mean absolute errors.
    public let nightMaes: [Double]
    /// Per-night root-mean-squared errors.
    public let nightRmses: [Double]
    /// Mean of `nightMaes`. `Double.nan` if no nights were evaluated.
    public let meanMae: Double
    /// Mean of `nightRmses`. `Double.nan` if no nights were evaluated.
    public let meanRmse: Double
    /// Number of nights that contributed to the average (≥ 0).
    public let nNights: Int

    public init(
        nightMaes: [Double],
        nightRmses: [Double],
        meanMae: Double,
        meanRmse: Double,
        nNights: Int
    ) {
        self.nightMaes  = nightMaes
        self.nightRmses = nightRmses
        self.meanMae    = meanMae
        self.meanRmse   = meanRmse
        self.nNights    = nNights
    }
}

// MARK: - leaveOneNightOut

/// Generic leave-one-night-out (LONO) evaluation helper.
///
/// Mirrors `units.py: leave_one_night_out(features, labels, night_ids, n_params)`.
///
/// Fits a degree-(n_params − 1) polynomial of `features` on `labels` using all but one night,
/// then evaluates on the left-out night. Returns a summary with per-night and aggregate MAE/RMSE.
///
/// OVERFIT GUARD: n_params ≤ ~(n_nights / 3). Prefer n_params=2 (linear) unless held-out
/// error clearly improves with higher degree and you have ≥ 3× as many nights.
///
/// - Parameters:
///   - features:  Per-sample feature values (e.g. ratio R, raw ADC count).
///   - labels:    Per-sample reference values in physical units.
///   - nightIds:  Integer night index per sample.
///   - nParams:   Number of model parameters (polynomial degree = nParams − 1). Default 2.
/// - Returns: `LeaveOneNightOutResult` with per-night and aggregate MAE/RMSE.
/// - Throws: `NumericError.emptyInput` if arrays are empty.
public func leaveOneNightOut(
    features: [Double],
    labels: [Double],
    nightIds: [Int],
    nParams: Int = 2
) throws -> LeaveOneNightOutResult {
    guard !features.isEmpty && !labels.isEmpty && !nightIds.isEmpty else {
        throw NumericError.emptyInput
    }

    let deg = nParams - 1  // polynomial degree

    // Collect unique night IDs, preserving sorted order (matching np.unique behavior)
    let uniqueNights = Array(Set(nightIds)).sorted()

    var nightMaes  = [Double]()
    var nightRmses = [Double]()

    for night in uniqueNights {
        // Split into train (all nights except this one) and test (this night)
        let testMask  = nightIds.enumerated().compactMap { $0.element == night ? $0.offset : nil }
        let trainMask = nightIds.enumerated().compactMap { $0.element != night ? $0.offset : nil }

        guard trainMask.count >= nParams else {
            // Not enough training samples for this night — skip (matching Python behavior)
            continue
        }

        let fTr = trainMask.map { features[$0] }
        let yTr = trainMask.map { labels[$0] }
        let fTe = testMask.map  { features[$0] }
        let yTe = testMask.map  { labels[$0] }

        // Fit polynomial on training set.
        // polyfit fails only if training set is too small for the degree — skip the night if so
        // (matches Python's `logger.warning("not enough training samples; skipping")`).
        let coeffs: [Double]
        do {
            coeffs = try polyfit(fTr, yTr, deg: deg)
        } catch {
            continue  // too few training samples for this degree — skip night
        }

        // Predict on test set
        let pred = fTe.map { polyval(coeffs, $0) }

        // Compute MAE and RMSE
        let errs = zip(pred, yTe).map { $0 - $1 }
        let mae  = errs.map { abs($0) }.reduce(0, +) / Double(errs.count)
        let rmse = (errs.map { $0 * $0 }.reduce(0, +) / Double(errs.count)).squareRoot()
        nightMaes.append(mae)
        nightRmses.append(rmse)
    }

    let meanMae  = nightMaes.isEmpty  ? Double.nan : nightMaes.reduce(0, +)  / Double(nightMaes.count)
    let meanRmse = nightRmses.isEmpty ? Double.nan : nightRmses.reduce(0, +) / Double(nightRmses.count)

    return LeaveOneNightOutResult(
        nightMaes:  nightMaes,
        nightRmses: nightRmses,
        meanMae:    meanMae,
        meanRmse:   meanRmse,
        nNights:    nightMaes.count
    )
}
