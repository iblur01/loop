import Foundation

// MARK: - CaloriesResult

/// Energy expenditure estimate for a heart-rate-instrumented exercise bout.
///
/// Mirrors `calories.py estimate_bout_calories()` semantics, split into three
/// components so the caller can display gross, active, and basal contributions.
public struct CaloriesResult {
    /// Active (above-threshold) calorie burn during the bout in kcal.
    public let activeKcal: Double
    /// Basal metabolic rate contribution prorated over the bout duration in kcal.
    public let bmrKcal: Double
    /// Total calorie burn = activeKcal + bmrKcal in kcal.
    public let totalKcal: Double

    public init(activeKcal: Double, bmrKcal: Double, totalKcal: Double) {
        self.activeKcal = activeKcal
        self.bmrKcal = bmrKcal
        self.totalKcal = totalKcal
    }
}

// MARK: - UserProfile

/// Anthropometric and demographic profile used for calorie estimation.
///
/// `Sex` is defined in `Strain.swift` (same module — no redeclaration needed).
public struct UserProfile {
    /// Age in years.
    public let ageYears: Double
    /// Body mass in kilograms.
    public let weightKg: Double
    /// Height in centimetres (converted to metres internally before applying coefficients).
    public let heightCm: Double
    /// Biological sex for coefficient set selection.
    public let sex: Sex

    public init(ageYears: Double, weightKg: Double, heightCm: Double, sex: Sex) {
        self.ageYears = ageYears
        self.weightKg = weightKg
        self.heightCm = heightCm
        self.sex = sex
    }
}

// MARK: - Coefficient sets

/// Sex-keyed coefficient sets ported from `calories.py _COEFFS`.
///
/// `workout_*` → Keytel et al. (2005) HR-based energy expenditure in kJ/min.
/// `resting_*` → revised Harris–Benedict BMR in kcal/day;
///               `restingHeight` is applied to height in METRES (= per-cm × 100).
private struct _CalorieCoeffs {
    let restingAlpha:  Double
    let restingWeight: Double
    let restingHeight: Double  // applied to height_m = height_cm / 100.0
    let restingAge:    Double
    let workoutHR:     Double
    let workoutWeight: Double
    let workoutAge:    Double
    let workoutAlpha:  Double
}

private let _coeffsMale = _CalorieCoeffs(
    restingAlpha:   88.362,
    restingWeight:  13.397,
    restingHeight:  479.9,    // 4.799 × 100 — applied to height_m
    restingAge:      5.677,
    workoutHR:       0.6309,
    workoutWeight:   0.1988,
    workoutAge:      0.2017,
    workoutAlpha:  -55.0969
)

private let _coeffsFemale = _CalorieCoeffs(
    restingAlpha:   447.593,
    restingWeight:    9.247,
    restingHeight:  309.8,    // 3.098 × 100 — applied to height_m
    restingAge:       4.33,
    workoutHR:       0.4472,
    workoutWeight:  -0.1263,
    workoutAge:      0.0740,
    workoutAlpha:  -20.4022
)

// Element-wise mean of male and female sets — used for unknown/nonbinary sex.
private let _coeffsNonbinary = _CalorieCoeffs(
    restingAlpha:   267.9775,
    restingWeight:   11.322,
    restingHeight:  394.85,
    restingAge:       5.0035,
    workoutHR:       0.53905,
    workoutWeight:   0.03625,
    workoutAge:      0.13785,
    workoutAlpha:  -37.74955
)

// MARK: - Private helpers

/// Active threshold fraction of heart-rate reserve (30 %).
/// Samples below `restingHR + 0.30 × HRR` count at the BMR rate; at/above, Keytel rate.
private let _activeHRRFraction: Double = 0.30

/// kJ/min → kcal/s divisor: 60 s/min × 4.184 kJ/kcal.
private let _workoutDivisor: Double = 251.04

private func _resolveCoeffs(sex: Sex) -> _CalorieCoeffs {
    switch sex {
    case .male:   return _coeffsMale
    case .female: return _coeffsFemale
    }
}

/// Revised Harris–Benedict BMR (Roza & Shock 1984) → kcal/s.
/// Height coefficient is applied to height in metres: `heightM = heightCm / 100.0`.
private func _restingKcalPerS(
    coeffs: _CalorieCoeffs,
    weightKg: Double,
    heightCm: Double,
    age: Double
) -> Double {
    let heightM = heightCm / 100.0
    let bmrKcalDay = (
        coeffs.restingAlpha
        + coeffs.restingWeight * weightKg
        + coeffs.restingHeight * heightM
        - coeffs.restingAge * age
    )
    return max(0.0, bmrKcalDay) / 86_400.0
}

/// Keytel 2005 HR-based active energy expenditure → kcal/s, clamped ≥ 0.
/// HR is capped at `hrmax` so the submaximal linear fit is not extrapolated.
private func _activeKcalPerS(
    coeffs: _CalorieCoeffs,
    hr: Double,
    hrmax: Double,
    weightKg: Double,
    age: Double
) -> Double {
    let eeKjMin = (
        coeffs.workoutHR * min(hr, hrmax)
        + coeffs.workoutWeight * weightKg
        + coeffs.workoutAge * age
        + coeffs.workoutAlpha
    )
    return max(0.0, eeKjMin) / _workoutDivisor
}

// MARK: - Public API

/// Estimate active + basal calorie burn for a heart-rate-instrumented exercise bout.
///
/// Each element of `hrSeries` is treated as 1 second of data (1 Hz store), matching
/// the Python oracle convention where 1 sample = 1 second.
///
/// The active/resting split follows the 30 % heart-rate reserve threshold:
/// a sample is "active" when `bpm ≥ restingHR + 0.30 × (hrmax − restingHR)`.
/// Active samples use Keytel 2005; resting samples use Harris–Benedict BMR.
///
/// - Parameters:
///   - hrSeries: Time-ordered `[(ts: Double, bpm: Double)]` for the bout window.
///   - profile: Anthropometric profile with age, weight, height (cm), and sex.
///   - hrmax: Effective HRmax; defaults to 220 if nil.
///   - restingHR: Day resting HR for active/resting split; defaults to 60 if nil.
/// - Returns: `CaloriesResult` with `activeKcal`, `bmrKcal`, and `totalKcal`.
public func estimateBoutCalories(
    hrSeries: [(ts: Double, bpm: Double)],
    profile: UserProfile,
    hrmax: Double? = nil,
    restingHR: Double? = nil
) -> CaloriesResult {
    let coeffs = _resolveCoeffs(sex: profile.sex)

    let effHRmax    = hrmax      ?? 220.0
    let effResting  = restingHR  ?? 60.0

    // Active when HR ≥ resting + 30 % of heart-rate reserve.
    let activeThreshold = effResting + _activeHRRFraction * (effHRmax - effResting)

    let restingRate = _restingKcalPerS(
        coeffs: coeffs,
        weightKg: profile.weightKg,
        heightCm: profile.heightCm,
        age: profile.ageYears
    )

    var activeKcal: Double = 0.0
    var bmrKcal:    Double = 0.0

    for sample in hrSeries {
        let bpm = sample.bpm
        if bpm < activeThreshold {
            bmrKcal += restingRate
        } else {
            activeKcal += _activeKcalPerS(
                coeffs: coeffs,
                hr: bpm,
                hrmax: effHRmax,
                weightKg: profile.weightKg,
                age: profile.ageYears
            )
        }
    }

    return CaloriesResult(
        activeKcal: activeKcal,
        bmrKcal: bmrKcal,
        totalKcal: activeKcal + bmrKcal
    )
}
