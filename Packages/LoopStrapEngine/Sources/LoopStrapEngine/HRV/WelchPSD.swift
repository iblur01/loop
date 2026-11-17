import Foundation
import Accelerate

// MARK: - WelchPSD constants

// Band limits for HRV frequency-domain analysis.
// LF: low-frequency (sympathovagal) band 0.04–0.15 Hz.
// HF: high-frequency (parasympathetic/respiratory) band 0.15–0.40 Hz.
private let _lfBandLo: Double = 0.04
private let _lfBandHi: Double = 0.15
private let _hfBandLo: Double = 0.15
private let _hfBandHi: Double = 0.40

// MARK: - welchPSD

/// Welch periodogram replicating `signal_psd(method="welch", normalize=True)` from neurokit2.
///
/// Computes a one-sided power spectral density estimate using Welch's method with:
/// - Periodic Hann window (scipy `sym=False` default for Welch)
/// - 50% overlap (noverlap = nperseg / 2)
/// - nfft = nextPowerOf2(nperseg * 2) for vDSP compatibility
/// - Density scaling: `1 / (fs * sum(w²))`; non-DC/non-Nyquist bins doubled
/// - Post-average normalization: `power /= max(power)` (D-02, mandatory for parity)
///
/// Input guards:
/// - Returns `([], [])` for `signal.count < 4` or all-zero signal (prevents divide-by-zero).
///
/// - Parameters:
///   - signal:       Real-valued signal at `samplingRate` Hz (typically 100 Hz RR interpolation).
///   - samplingRate: Sampling frequency in Hz (default 100.0).
///   - minFrequency: Minimum frequency — used to compute nperseg cap (default 0.04 Hz).
/// - Returns: `(frequencies: [Double], power: [Double])` — one-sided, normalized by max power.
public func welchPSD(
    _ signal: [Double],
    samplingRate: Double = 100.0,
    minFrequency: Double = 0.04
) -> (frequencies: [Double], power: [Double]) {
    let n = signal.count
    guard n >= 4 else { return ([], []) }

    // Mean detrend — mirrors signal_psd line 136: `signal = signal - np.mean(signal)`
    let mu = signal.reduce(0.0, +) / Double(n)
    let detrended = signal.map { $0 - mu }

    // npersegPython = min(N//2, int(2/minFreq * fs)) — D-03, RESEARCH.md resolved Q2
    // For typical HRV lengths (N < 10000), N//2 is the binding constraint.
    let npersegPython = min(n / 2, Int(2.0 / minFrequency * samplingRate))
    // nfft = nperseg * 2 (zero-padding, Pitfall 1) then rounded up to power-of-2 for vDSP
    let nfftPython = npersegPython * 2
    let nfft = nextPowerOf2(nfftPython)  // vDSP.FFT requires power-of-2 (Pitfall 2)
    let nperseg = nfft / 2               // keep nperseg consistent with nfft

    let noverlap = nperseg / 2
    let step = nperseg - noverlap

    // Periodic Hann window: w[n] = 0.5 * (1 - cos(2π*n/nperseg)), n=0..nperseg-1
    // Divide by nperseg (NOT nperseg-1) — this is the DFT-even / periodic form
    // that scipy.signal.welch uses (sym=False). See Pitfall 6.
    let hann = (0..<nperseg).map { 0.5 * (1.0 - cos(2.0 * .pi * Double($0) / Double(nperseg))) }
    let windowNorm = hann.reduce(0.0) { $0 + $1 * $1 }  // sum(w²) for density normalization

    let nFreqs = nfft / 2 + 1
    var psdAccum = [Double](repeating: 0.0, count: nFreqs)
    var segCount = 0

    var start = 0
    while start + nperseg <= n {
        let seg = Array(detrended[start..<(start + nperseg)])

        // Apply Hann window element-wise
        let windowed = zip(seg, hann).map { $0 * $1 }

        // Zero-pad to nfft
        let padded = windowed + [Double](repeating: 0.0, count: nfft - nperseg)

        // FFT via vDSP (nfft is guaranteed power-of-2)
        let segPow = _vdspFFTPower(padded, nfft: nfft)

        // One-sided density scaling (Pitfall 7):
        // - DC (k=0): scale = 1/(fs * windowNorm), no doubling
        // - Interior (k=1..nFreqs-2): scale = 1/(fs * windowNorm), then ×2
        // - Nyquist (k=nFreqs-1): scale = 1/(fs * windowNorm), no doubling
        let scale = 1.0 / (samplingRate * windowNorm)
        for k in 0..<nFreqs {
            let raw = segPow[k] * scale
            psdAccum[k] += (k == 0 || k == nFreqs - 1) ? raw : raw * 2.0
        }

        segCount += 1
        start += step
    }

    guard segCount > 0 else { return ([], []) }

    // Average across all segments (Pitfall 3: must average BEFORE normalization)
    let avgPsd = psdAccum.map { $0 / Double(segCount) }

    // Post-average normalization: power /= max(power) — D-02, mandatory for parity
    // If all-zero after detrending (constant signal), max == 0 → return empty.
    let maxP = avgPsd.max() ?? 0.0
    guard maxP > 0.0 else { return ([], []) }
    let normalizedPsd = avgPsd.map { $0 / maxP }

    // Frequency axis: f[k] = k * fs / nfft
    let freqs = (0..<nFreqs).map { Double($0) * samplingRate / Double(nfft) }

    return (freqs, normalizedPsd)
}

// MARK: - Band integration

/// Integrate normalized PSD power over a frequency band using the trapezoidal rule.
///
/// Mirrors `np.trapz(power[band], x=freq[band])` in neurokit2's `signal_power.py`.
///
/// - Parameters:
///   - frequencies: Frequency axis from `welchPSD`.
///   - power:       Normalized power from `welchPSD` (same length as `frequencies`).
///   - lo:          Lower bound of the band in Hz (inclusive).
///   - hi:          Upper bound of the band in Hz (inclusive).
/// - Returns: Integrated band power, or `.nan` if fewer than 2 bins fall in the band.
public func bandPower(
    frequencies: [Double],
    power: [Double],
    lo: Double,
    hi: Double
) -> Double {
    let inBand = zip(frequencies, power).filter { $0.0 >= lo && $0.0 <= hi }
    guard inBand.count >= 2 else { return .nan }
    let freqs = inBand.map(\.0)
    let pows  = inBand.map(\.1)
    var area = 0.0
    for i in 0..<(freqs.count - 1) {
        area += (pows[i] + pows[i + 1]) / 2.0 * (freqs[i + 1] - freqs[i])
    }
    return area
}

// MARK: - Helpers

/// Round `n` up to the nearest power of 2.
///
/// Used to guarantee vDSP.FFT compatibility (Pitfall 2).
/// Returns 1 for non-positive input.
private func nextPowerOf2(_ n: Int) -> Int {
    guard n > 0 else { return 1 }
    var p = 1
    while p < n { p <<= 1 }
    return p
}

/// Process-lifetime cache of vDSP FFT setups, keyed by `log2n`.
///
/// A setup holds precomputed twiddle-factor tables and is expensive to build; Apple's
/// guidance is to create it once and reuse it across FFTs of the same size. `welchPSD`
/// previously created AND destroyed a setup on every segment FFT — and `welchPSD` itself
/// runs once per stride anchor in `extractFeatures`, so a single night triggered on the
/// order of ~1.4k setup create/destroy pairs, dominating sleep-staging CPU.
///
/// The set of distinct sizes is tiny: `nfft` is a power of two bounded by the HRV window
/// length, so a handful of entries covers every call. Setups are never freed (process
/// lifetime, negligible memory). `@unchecked Sendable` + `NSLock`: the underlying
/// `FFTSetupD` is an opaque pointer that vDSP documents as safe to share across concurrent
/// FFT calls once built, and the lock guards only the dictionary mutation — this lets the
/// per-night parallel sleep detection share one cache.
private final class FFTSetupCache: @unchecked Sendable {
    static let shared = FFTSetupCache()
    private var setups: [vDSP_Length: FFTSetupD] = [:]
    private let lock = NSLock()

    func setup(log2n: vDSP_Length) -> FFTSetupD? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = setups[log2n] { return existing }
        guard let created = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        setups[log2n] = created
        return created
    }
}

/// Compute `|X[k]|²` for k = 0..nfft/2 via vDSP Double-precision FFT.
///
/// Uses the C-level `vDSP_fft_zopD` (out-of-place complex FFT) which is the only
/// vDSP path that supports Double precision. The high-level `vDSP.FFT` class only
/// exposes Float (`DSPSplitComplex`), not Double (`DSPDoubleSplitComplex`), in the
/// current Apple SDK.
///
/// Input `padded` must have length exactly `nfft` (a power of 2).
/// Returns `nfft/2 + 1` power values (un-scaled — caller applies density scaling).
///
/// The FFT setup is fetched from `FFTSetupCache` (built once per `log2n`, never freed) —
/// see that type for why the previous per-call create/destroy was the dominant cost.
private func _vdspFFTPower(_ padded: [Double], nfft: Int) -> [Double] {
    let log2n = vDSP_Length(log2(Double(nfft)).rounded())
    guard let setup = FFTSetupCache.shared.setup(log2n: log2n) else {
        return [Double](repeating: 0.0, count: nfft / 2 + 1)
    }

    var realIn  = padded
    var imagIn  = [Double](repeating: 0.0, count: nfft)
    var realOut = [Double](repeating: 0.0, count: nfft)
    var imagOut = [Double](repeating: 0.0, count: nfft)

    realIn.withUnsafeMutableBufferPointer { rIn in
        imagIn.withUnsafeMutableBufferPointer { iIn in
            realOut.withUnsafeMutableBufferPointer { rOut in
                imagOut.withUnsafeMutableBufferPointer { iOut in
                    var splitIn  = DSPDoubleSplitComplex(realp: rIn.baseAddress!, imagp: iIn.baseAddress!)
                    var splitOut = DSPDoubleSplitComplex(realp: rOut.baseAddress!, imagp: iOut.baseAddress!)
                    vDSP_fft_zopD(setup, &splitIn, 1, &splitOut, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
        }
    }

    // |X[k]|² = realOut[k]² + imagOut[k]²
    let nOut = nfft / 2 + 1
    return (0..<nOut).map { k in realOut[k] * realOut[k] + imagOut[k] * imagOut[k] }
}
