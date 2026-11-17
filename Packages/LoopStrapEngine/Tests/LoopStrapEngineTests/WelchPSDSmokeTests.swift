import XCTest
@testable import LoopStrapEngine
import Foundation

// MARK: - WelchPSD smoke tests

/// Minimal smoke tests for welchPSD() validating the vDSP FFT path on known synthetic signals.
///
/// These tests confirm the function contract (non-empty output, normalized max ≤ 1.0,
/// edge-case guards) without requiring oracle fixture files. Full parity tests
/// (fixture-driven atol on PSD bins) are in WelchPSDParityTests (Plan 03).
final class WelchPSDSmokeTests: XCTestCase {

    // MARK: - Single-tone smoke test

    func testWelchPSDSingleTone_returnsNonEmptyResult() {
        // 1000-sample sine at 0.1 Hz, sampled at 100 Hz (10 s)
        let signal = (0..<1000).map { Double($0) * 0.01 }.map { sin(2.0 * .pi * 0.1 * $0) }
        let (freqs, power) = welchPSD(signal, samplingRate: 100.0)
        XCTAssertFalse(freqs.isEmpty, "welchPSD returned empty frequencies on 1000-sample sine wave")
        XCTAssertFalse(power.isEmpty, "welchPSD returned empty power on 1000-sample sine wave")
        XCTAssertEqual(freqs.count, power.count, "freqs and power must have equal length")
        let maxPow = power.max() ?? 0.0
        XCTAssertGreaterThan(maxPow, 0.0, "normalized power must have max > 0")
        XCTAssertLessThanOrEqual(maxPow, 1.0 + 1e-9, "normalized power must have max <= 1.0")
    }

    // MARK: - Edge case: all-zero signal

    func testWelchPSD_allZero_returnsEmpty() {
        let (freqs, power) = welchPSD([Double](repeating: 0.0, count: 500), samplingRate: 100.0)
        XCTAssertTrue(freqs.isEmpty && power.isEmpty, "all-zero signal must return empty arrays")
    }

    // MARK: - Edge case: too short

    func testWelchPSD_tooShort_returnsEmpty() {
        let (freqs, power) = welchPSD([1.0, 2.0, 3.0], samplingRate: 100.0)
        XCTAssertTrue(freqs.isEmpty && power.isEmpty, "< 4 samples must return empty arrays")
    }
}
