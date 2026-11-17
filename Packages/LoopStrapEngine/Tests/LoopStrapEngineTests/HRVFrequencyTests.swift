import XCTest
@testable import LoopStrapEngine

// MARK: - HRVFrequency unit tests

/// Unit tests for the HRVFrequency.swift pipeline (Plan 05-02).
///
/// Tests cover:
/// - Empty input returns allNaN
/// - Input below FREQ_MIN_BEATS=120 after filterRR returns allNaN
/// - Input with 130 valid intervals returns finite lf and hf
/// - LFHF ratio matches lf/hf when hf > 0
/// - filterRR is applied first (count guard is post-filter)
final class HRVFrequencyTests: XCTestCase {

    // MARK: - Edge cases: allNaN returns

    func testHRVFrequency_emptyInput_returnsAllNaN() {
        let result = hrvFrequency([])
        XCTAssertTrue(result.lf.isNaN, "lf must be NaN for empty input")
        XCTAssertTrue(result.hf.isNaN, "hf must be NaN for empty input")
        XCTAssertTrue(result.lfhf.isNaN, "lfhf must be NaN for empty input")
    }

    func testHRVFrequency_belowMinBeats_returnsAllNaN() {
        // 10 intervals, well below FREQ_MIN_BEATS=120 — even all in range
        let result = hrvFrequency(Array(repeating: 800.0, count: 10))
        XCTAssertTrue(result.lf.isNaN, "lf must be NaN when count < 120")
        XCTAssertTrue(result.hf.isNaN, "hf must be NaN when count < 120")
        XCTAssertTrue(result.lfhf.isNaN, "lfhf must be NaN when count < 120")
    }

    func testHRVFrequency_exactlyMinBeats_returnsAllNaN() {
        // Exactly 119 intervals (one below threshold) — should return allNaN
        let result = hrvFrequency(Array(repeating: 800.0, count: 119))
        XCTAssertTrue(result.lf.isNaN, "lf must be NaN for count == 119 (< 120)")
    }

    func testHRVFrequency_outOfRangeIntervals_filteredToZero_returnsAllNaN() {
        // 200 intervals but all out of the 300–2000 ms range — filterRR yields 0
        let result = hrvFrequency(Array(repeating: 100.0, count: 200))
        XCTAssertTrue(result.lf.isNaN, "lf must be NaN when filterRR yields 0 valid intervals")
    }

    // MARK: - Valid inputs

    func testHRVFrequency_130ValidIntervals_returnsFiniteResult() {
        // 130 intervals with physiological variation — avoids constant-signal guard in welchPSD.
        // A constant-valued input (e.g. repeating: 800) is correctly rejected by the all-zero PSD
        // guard inside welchPSD (mean-detrend → all zeros → maxP == 0 → returns ([], [])).
        var intervals: [Double] = []
        for i in 0..<130 {
            intervals.append(800.0 + (i % 2 == 0 ? 30.0 : -30.0))
        }
        let result = hrvFrequency(intervals)
        XCTAssertTrue(result.lf.isFinite, "lf must be finite for 130 valid intervals with HRV")
        XCTAssertTrue(result.hf.isFinite, "hf must be finite for 130 valid intervals with HRV")
    }

    func testHRVFrequency_lfhfRatioMatchesLFoverHF() {
        // Generate 130 valid intervals with enough variability for PSD
        var intervals: [Double] = []
        for i in 0..<130 {
            // Slight variation around 800 ms to produce non-trivial PSD
            intervals.append(800.0 + Double(i % 5) * 20.0)
        }
        let result = hrvFrequency(intervals)
        guard !result.hf.isNaN && result.hf > 0 else { return }
        let expectedLFHF = result.lf / result.hf
        XCTAssertEqual(result.lfhf, expectedLFHF, accuracy: 1e-10, "lfhf must equal lf/hf")
    }

    func testHRVFrequency_filterRRAppliedFirst() {
        // Mix of valid (800 ms) and invalid (50 ms) intervals.
        // If filterRR is applied first, only valid ones count toward the 120 threshold.
        // 100 valid + 50 invalid = 150 total, but only 100 valid → below threshold → allNaN
        var mixed: [Double] = Array(repeating: 800.0, count: 100)
        mixed += Array(repeating: 50.0, count: 50)
        let result = hrvFrequency(mixed)
        // After filterRR: 100 valid intervals < 120 → should return allNaN
        XCTAssertTrue(result.lf.isNaN, "filterRR must be applied before threshold check")
    }

    // MARK: - HRVFrequencyResult struct

    func testHRVFrequencyResult_allNaN_allFieldsNaN() {
        let r = HRVFrequencyResult.allNaN
        XCTAssertTrue(r.lf.isNaN)
        XCTAssertTrue(r.hf.isNaN)
        XCTAssertTrue(r.lfhf.isNaN)
    }
}
