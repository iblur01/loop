import Foundation

// MARK: - RespRate constants

// Band limits for breathing frequency (0.1–0.5 Hz = 6–30 BrPM).
// Respiration (0.1–0.5 Hz) is at/below the 0.5 Hz Nyquist for 1 Hz sampling — detectable.
// Cardiac (~1 Hz and above) is above Nyquist — NOT recoverable at 1 Hz.
private let _respBandLo: Double = 0.1   // Hz
private let _respBandHi: Double = 0.5   // Hz

// Default constants for public function signatures. Public visibility required for
// use as default argument values. Leading underscore signals implementation details.
public let _respNpersegDefault: Int = 120
public let _respSlope:  Double = 10.0 / 512.0  // bpm per ADC count (~0.01953)
public let _respOffset: Double = 6.0            // bpm at raw=0

// MARK: - respRateBpm

/// APPROXIMATE — single-sample legacy interface: convert a raw ADC/sensor count to BrPM.
///
/// Mirrors `units.py: resp_rate_bpm(raw)`.
///
/// Method: `bpm = RESP_SLOPE * raw + RESP_OFFSET`  (synthetic, un-calibrated).
/// Retained for backwards compatibility. For a physiologically meaningful estimate,
/// use `respRateFromSignal()` on a window of values.
///
/// - Parameter raw: Raw ADC/sensor count (any float).
/// - Returns: Estimated respiratory rate in breaths per minute.
public func respRateBpm(raw: Double) -> Double {
    return _respSlope * raw + _respOffset
}

// MARK: - respRateFromSignal

/// APPROXIMATE — estimate respiratory rate (BrPM) from a 1 Hz waveform signal.
///
/// Mirrors `units.py: resp_rate_from_signal(signal, fs, nperseg, method)`.
///
/// Uses a Welch periodogram to identify the dominant frequency in the respiratory band
/// (0.1–0.5 Hz = 6–30 BrPM), then converts to breaths/min. This is the primary path.
///
/// // nk2xcorr path deliberately excluded — neurokit2 has no Swift equivalent.
/// // See REQUIREMENTS.md Out-of-Scope and RESEARCH.md Open Question 1.
/// // All method values (including "nk2xcorr") fall through to the Welch path.
///
/// - Parameters:
///   - signal:  1D array of the raw resp field (or a detrended variant).
///   - fs:      Sampling rate in Hz (default 1.0).
///   - nperseg: Welch window length in samples (default 120 = 2 min at 1 Hz).
///   - method:  'welch' (default) or any other value (falls through to Welch).
/// - Returns: Estimated respiratory rate in BrPM, or nil if estimation failed.
public func respRateFromSignal(
    signal: [Double],
    fs: Double = 1.0,
    nperseg: Int = _respNpersegDefault,
    method: String = "welch"
) throws -> Double? {
    // nk2xcorr path deliberately excluded — neurokit2 has no Swift equivalent.
    // See REQUIREMENTS.md Out-of-Scope and RESEARCH.md Open Question 1.
    // All method values fall through to Welch below.

    // Need at least 2 full cycles of the lowest band frequency
    let minSamples = 2 * Int(1.0 / _respBandLo)  // 2 * (1/0.1) = 20 samples
    guard signal.count >= minSamples else { return nil }

    return _respRateWelch(signal, fs: fs, nperseg: nperseg)
}

// MARK: - Welch PSD implementation

/// Welch periodogram peak in 0.1–0.5 Hz → BrPM. Primary path.
///
/// Mirrors `units.py: _resp_rate_welch(arr, fs, nperseg)`.
///
/// Implements Welch's method using overlapping Hann-windowed DFT segments.
/// Frequency resolution: Δf = fs / nperseg_actual.
///
/// Pure Swift DFT (O(N·nperseg)) — adequate for the small segment sizes used here
/// (nperseg ≤ 300 samples). Uses Accelerate/FFT could replace this for production.
private func _respRateWelch(_ arr: [Double], fs: Double, nperseg: Int) -> Double? {
    // Guard: NaN in input → return nil
    guard arr.allSatisfy({ $0.isFinite }) else { return nil }

    let mu = arr.reduce(0.0, +) / Double(arr.count)
    let detrended = arr.map { $0 - mu }

    guard !detrended.allSatisfy({ $0 == 0 }) else { return nil }

    let npersegActual = min(nperseg, arr.count)
    let noverlap = npersegActual / 2
    let step = npersegActual - noverlap

    // Collect Welch segments and average their PSDs
    var psdAccum: [Double]? = nil
    var segCount = 0

    var start = 0
    while start + npersegActual <= arr.count {
        let segment = Array(detrended[start..<(start + npersegActual)])
        // Apply Hann window
        let windowed = _applyHann(segment)
        // Compute one-sided DFT power spectrum
        let power = _dftPower(windowed)

        if psdAccum == nil {
            psdAccum = [Double](repeating: 0.0, count: power.count)
        }
        for i in 0..<power.count {
            psdAccum![i] += power[i]
        }
        segCount += 1
        start += step
    }

    // segCount == 0 is unreachable: minSamples guard and npersegActual = min(nperseg, arr.count)
    // guarantee the while loop runs at least one iteration.
    assert(segCount > 0, "_respRateWelch: segCount must be > 0 — unreachable given minSamples guard")
    guard let psd = psdAccum else { return nil }

    // Average across segments
    let nfft = npersegActual
    let avgPsd = psd.map { $0 / Double(segCount) }

    // Build frequency array: f[k] = k * fs / nfft for k in 0..<(nfft/2 + 1)
    let nFreqs = nfft / 2 + 1
    let freqs = (0..<nFreqs).map { Double($0) * fs / Double(nfft) }

    // Find peak frequency in the respiratory band [_respBandLo, min(_respBandHi, fs/2)]
    let bandHi = min(_respBandHi, fs / 2.0)
    var bestFreq: Double? = nil
    var bestPower = -Double.infinity

    for k in 0..<min(nFreqs, avgPsd.count) {
        let f = freqs[k]
        if f >= _respBandLo && f <= bandHi {
            if avgPsd[k] > bestPower {
                bestPower = avgPsd[k]
                bestFreq = f
            }
        }
    }

    guard let peakFreq = bestFreq else { return nil }
    return peakFreq * 60.0  // Hz → BrPM
}

// MARK: - DFT helpers

/// Apply Hann window to a signal segment.
///
/// w[n] = 0.5 * (1 - cos(2π n / (N-1)))  for n = 0, ..., N-1
/// Matches scipy's default Hann window used by `scipy.signal.welch`.
private func _applyHann(_ x: [Double]) -> [Double] {
    let n = x.count
    guard n > 1 else { return x }
    return x.enumerated().map { i, xi in
        let w = 0.5 * (1.0 - cos(2.0 * .pi * Double(i) / Double(n - 1)))
        return xi * w
    }
}

/// Compute the one-sided power spectral density of a real-valued signal via DFT.
///
/// Returns `nfft/2 + 1` power values (one-sided, matching scipy's one-sided PSD).
/// Each power value is `|X[k]|² / (fs * sum(w²))` scaled for Welch periodogram.
/// For parity purposes (finding the peak frequency), exact scaling cancels out —
/// we only need relative powers within the band.
private func _dftPower(_ x: [Double]) -> [Double] {
    let n = x.count
    let nOut = n / 2 + 1
    var power = [Double](repeating: 0.0, count: nOut)

    // Hann window normalization: sum of squared window values
    // For a Hann window of length n: sum(w²) ≈ 3n/8
    // (not needed for peak finding but kept for structural completeness)

    for k in 0..<nOut {
        var re = 0.0
        var im = 0.0
        let angle = -2.0 * .pi * Double(k) / Double(n)
        for j in 0..<n {
            re += x[j] * cos(angle * Double(j))
            im += x[j] * sin(angle * Double(j))
        }
        // One-sided: double the power for non-DC, non-Nyquist bins
        let p = re * re + im * im
        if k == 0 || (n % 2 == 0 && k == nOut - 1) {
            power[k] = p
        } else {
            power[k] = 2.0 * p
        }
    }
    return power
}
