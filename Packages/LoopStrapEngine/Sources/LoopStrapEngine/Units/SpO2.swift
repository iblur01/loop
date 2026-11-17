import Foundation

// MARK: - SpO2 constants

// Published default calibration constants (un-fitted — TI SLAA655 textbook values).
// SpO2 = SPO2_A − SPO2_B · R  (R = ratio-of-ratios; see §1.3 of spec)
//
// IMPORTANT — UN-FITTED APPROXIMATION:
// These are device-generic starting points only. For a reflectance wrist sensor like WHOOP
// the true (a, b) depend on LED wavelengths, photodiode spectral response, optics geometry,
// and whatever the firmware already did to the 1 Hz field. Calibrate with fitSpo2().
// Default constants for public function signatures.
// Public visibility required for default argument use in public functions.
// Leading underscore signals implementation detail, not primary public API.
public let _spo2A: Double = 110.0   // [APPROXIMATE — un-calibrated] linear intercept, %SpO2
public let _spo2B: Double = 25.0    // [APPROXIMATE — un-calibrated] linear slope (> 0 required)

// Physiological clamp: values outside are artefact
private let _spo2ClampLo: Double = 70.0   // %
private let _spo2ClampHi: Double = 100.0  // %

// Motion-rejection: perfusion ceiling (AC/DC ratio > this → motion artefact).
// Resting perfusion index is 0.2–2 %; 10 % is a conservative reject threshold.
private let _spo2PerfusionCeiling: Double = 0.10  // fraction

// MARK: - Internal helpers

/// Apply empirical linear map SpO2 = a − b·R, clamped [70, 100].
///
/// Mirrors `units.py: _spo2_from_R(R, a, b)`.
private func _spo2FromR(_ R: Double, a: Double = _spo2A, b: Double = _spo2B) -> Double {
    let raw = a - b * R
    return max(_spo2ClampLo, min(_spo2ClampHi, raw))
}

// MARK: - spo2Percent

/// APPROXIMATE — single-sample SpO2 estimate from raw red and IR ADC counts.
///
/// Mirrors `units.py: spo2_percent(red, ir)`.
///
/// Method: treats raw red/ir as a crude proxy for the ratio-of-ratios R ≈ red/ir,
/// then applies the empirical linear formula SpO2 ≈ SPO2_A − SPO2_B·R, clamped [70, 100].
///
/// - Parameters:
///   - red: Raw red-channel ADC count.
///   - ir:  Raw IR-channel ADC count.
/// - Returns: SpO2 estimate in percent, clamped to [70.0, 100.0].
/// - Throws: `UnitsError.divisionByZero` if ir == 0.
public func spo2Percent(red: Double, ir: Double) throws -> Double {
    guard ir != 0 else { throw UnitsError.divisionByZero }
    let R = red / ir
    return _spo2FromR(R)
}

// MARK: - spo2FeatureWindow

/// Compute the robust ratio-of-ratios feature R over a window of 1 Hz samples.
///
/// Mirrors `units.py: spo2_feature_window(reds, irs, detrend, reject_motion)`.
///
/// Method (§1.3 of spec):
///   DC_x  = mean(x)                — baseline
///   AC_x  = 1.4826 * MAD(x)       — robust pulsatile surrogate (motion-robust)
///   R     = (AC_red / DC_red) / (AC_ir / DC_ir)
///
/// Detrending (default on): removes a linear trend over the window before computing AC.
/// Motion rejection (default on): returns nil if perfusion index exceeds 10%.
///
/// - Parameters:
///   - reds: Red-channel ADC counts over the window (≥ 2 samples).
///   - irs:  IR-channel ADC counts over the window.
///   - detrend: Whether to remove linear trend before AC estimation.
///   - rejectMotion: Whether to reject high-motion windows.
/// - Returns: R value or nil if the window is rejected or degenerate.
/// - Throws: `UnitsError.emptyInput` if arrays are empty.
///           `UnitsError.lengthMismatch` if arrays have different lengths.
public func spo2FeatureWindow(
    reds: [Double],
    irs: [Double],
    detrend: Bool = true,
    rejectMotion: Bool = true
) throws -> Double? {
    guard reds.count == irs.count else {
        throw UnitsError.lengthMismatch(lhs: reds.count, rhs: irs.count)
    }
    guard !reds.isEmpty else { throw UnitsError.emptyInput }

    var redArr = reds
    var irArr  = irs

    // DC = mean of each channel (pre-detrend). Used for:
    //   1. Off-wrist guard (pre-detrend is required — detrend forces mean to ~0).
    //   2. R ratio and motion-rejection normalisation baseline.
    // This matches units.py's two-step approach: dc = mean(original), ac = robustSpread(detrended).
    let dcRed = redArr.reduce(0, +) / Double(redArr.count)
    let dcIr  = irArr.reduce(0, +) / Double(irArr.count)

    if dcRed <= 0.0 || dcIr <= 0.0 {
        return nil  // sensor off-wrist or saturated
    }

    if redArr.count < 2 {
        return nil  // cannot compute AC
    }

    if detrend {
        // Remove linear trend (least-squares fit) from each channel.
        // t = 0, 1, ..., n-1; n >= 2 guaranteed above so deg-1 polyfit always succeeds.
        // Use do/catch so detrend errors are surfaced as window rejection rather than silently
        // leaving redArr/irArr un-detrended (which would cause parity divergence).
        let t = (0..<redArr.count).map { Double($0) }
        do {
            let redCoeffs = try polyfit(t, redArr, deg: 1)
            let redTrend = t.map { polyval(redCoeffs, $0) }
            redArr = zip(redArr, redTrend).map { $0 - $1 }
        } catch {
            return nil  // detrend failed — treat window as degenerate
        }
        do {
            let irCoeffs = try polyfit(t, irArr, deg: 1)
            let irTrend = t.map { polyval(irCoeffs, $0) }
            irArr = zip(irArr, irTrend).map { $0 - $1 }
        } catch {
            return nil  // detrend failed — treat window as degenerate
        }
    }

    // AC = robust spread of detrended signal; DC = pre-detrend mean (stable baseline).
    let acRed = _robustSpread(redArr)
    let acIr  = _robustSpread(irArr)

    if acIr < 1e-6 * dcIr {
        return nil  // IR channel effectively flat → R undefined
    }

    if rejectMotion {
        // Use pre-detrend DC (dcRed/dcIr) for perfusion index — consistent with R ratio below.
        let piRed = acRed / dcRed
        let piIr  = acIr  / dcIr
        if piRed > _spo2PerfusionCeiling || piIr > _spo2PerfusionCeiling {
            return nil  // motion artefact — discard this window
        }
    }

    // R ratio uses pre-detrend DC as normalisation baseline, post-detrend AC for pulsatile amplitude.
    let R = (acRed / dcRed) / (acIr / dcIr)
    return R
}

// MARK: - spo2PercentWindow

/// APPROXIMATE — windowed SpO2 estimate using robust AC/DC decomposition.
///
/// Mirrors `units.py: spo2_percent_window(reds, irs, a, b)`.
///
/// Falls back to the single-sample ratio when the window is rejected (motion)
/// or degenerate (< 2 samples).
///
/// - Parameters:
///   - reds: Sequence of raw red-channel ADC counts over the window.
///   - irs:  Sequence of raw IR-channel ADC counts over the window.
///   - a:    SpO2 = a − b·R intercept (default 110.0; use fitted value).
///   - b:    SpO2 = a − b·R slope (default 25.0; use fitted value).
/// - Returns: SpO2 estimate in percent, clamped to [70.0, 100.0].
/// - Throws: `UnitsError.emptyInput` if arrays are empty.
///           `UnitsError.lengthMismatch` if arrays have different lengths.
///           `UnitsError.divisionByZero` if DC (mean) of IR channel is zero.
public func spo2PercentWindow(
    reds: [Double],
    irs: [Double],
    a: Double = _spo2A,
    b: Double = _spo2B
) throws -> Double {
    guard reds.count == irs.count else {
        throw UnitsError.lengthMismatch(lhs: reds.count, rhs: irs.count)
    }
    guard !reds.isEmpty else { throw UnitsError.emptyInput }

    // Single-sample path
    if reds.count < 2 {
        return try spo2Percent(red: reds[0], ir: irs[0])
    }

    // Try windowed ratio-of-ratios
    let R = try spo2FeatureWindow(reds: reds, irs: irs)
    if let R = R {
        return _spo2FromR(R, a: a, b: b)
    }

    // Motion-rejected or degenerate — fall back to crude single-sample DC ratio
    let dcRed = reds.reduce(0, +) / Double(reds.count)
    let dcIr  = irs.reduce(0, +) / Double(irs.count)
    guard dcIr != 0.0 else { throw UnitsError.divisionByZero }
    let rCrude = dcRed / dcIr
    return _spo2FromR(rCrude, a: a, b: b)
}
