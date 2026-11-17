import Foundation

// MARK: - SkinTemp constants

// Published default calibration constants (un-fitted empirical approximation).
//
// T_°C = SKIN_TEMP_SLOPE * raw_count + SKIN_TEMP_OFFSET
//
// Anchor: raw=930 → 33°C (median resting on-wrist skin temp).
// IMPORTANT — UN-FITTED APPROXIMATION:
//   We do not know the thermistor's R₀, β, divider topology, or ADC resolution.
//   This linear map is an empirical substitute adequate for TREND analysis only.
//   Deviation-from-baseline (skinTempDeviation) cancels the unknown offset and
//   is the more trustworthy output. Calibrate with fitSkinTemp() when WHOOP
//   export data is available.
// Default constants for public function signatures.
// Leading underscore signals these are implementation details, not part of the public API.
// Public visibility is required so they can be used as default argument values in public functions.
public let _skinTempSlopeDefault: Double  = 0.02    // [APPROXIMATE] °C per ADC count
public let _skinTempOffsetDefault: Double = 14.4    // [APPROXIMATE] °C at count=0

// MARK: - skinTempCelsius

/// APPROXIMATE — convert raw thermistor ADC count to degrees Celsius.
///
/// Mirrors `units.py: skin_temp_celsius(raw, slope, offset)`.
///
/// Method: uncalibrated linear fit T = slope * raw + offset.
/// Default calibrated so raw ≈ 930 → 33°C (median resting wrist temp).
///
/// UNCALIBRATED ABSOLUTE — use for TREND and relative comparisons only.
///
/// - Parameters:
///   - raw:    Raw ADC count from the skin-temperature sensor.
///   - slope:  °C per ADC count (default SKIN_TEMP_SLOPE = 0.02; use fitted value).
///   - offset: °C at count=0  (default SKIN_TEMP_OFFSET = 14.4; use fitted value).
/// - Returns: Estimated skin temperature in degrees Celsius.
public func skinTempCelsius(
    raw: Double,
    slope: Double = _skinTempSlopeDefault,
    offset: Double = _skinTempOffsetDefault
) -> Double {
    return slope * raw + offset
}

// MARK: - skinTempDeviation

/// APPROXIMATE — compute per-sample skin-temperature deviation from a personal baseline.
///
/// Mirrors `units.py: skin_temp_deviation(raw_series, baseline_raw, slope)`.
///
/// Because deviation subtracts the baseline:
///     deviation = slope * (raw - baseline_raw)
/// the unknown additive offset cancels entirely. Only the slope matters.
/// This mirrors what WHOOP actually shows (nightly deviation from trailing-median baseline).
///
/// - Parameters:
///   - rawSeries:   Sequence of raw ADC counts (e.g. nightly mean per sample).
///   - baselineRaw: Baseline ADC count (e.g. trailing 14-night median during sleep).
///   - slope:       °C per ADC count (default SKIN_TEMP_SLOPE; use fitted slope).
/// - Returns: Array of deviation values in °C, same length as rawSeries.
public func skinTempDeviation(
    rawSeries: [Double],
    baselineRaw: Double,
    slope: Double = _skinTempSlopeDefault
) -> [Double] {
    return rawSeries.map { slope * ($0 - baselineRaw) }
}
