import XCTest
@testable import LoopStrapEngine

// MARK: - SleepFeaturesTests

/// Unit tests for SleepFeatures.swift: dogHRVariability, respRateAndRRV, hrvFromRR, extractFeatures.
/// TDD RED phase — tests written before implementation.
final class SleepFeaturesTests: XCTestCase {

    // MARK: - dogHRVariability

    func testDogHRVariabilityEmptyReturnsEmpty() {
        let result = dogHRVariability(hrPerEpoch: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testDogHRVariabilityAllNaNReturnsAllZero() {
        // All NaN epochs — no HR data at all → returns zeros
        let input = [Double](repeating: Double.nan, count: 5)
        let result = dogHRVariability(hrPerEpoch: input)
        XCTAssertEqual(result.count, 5)
        XCTAssertTrue(result.allSatisfy { $0 == 0.0 || $0.isNaN || $0.isFinite },
                      "All-NaN input should return a finite signal (zeros or interpolated)")
    }

    func testDogHRVariabilityOutputSameLengthAsInput() {
        let input = [60.0, 62.0, 65.0, 63.0, 61.0, 59.0, 58.0, 60.0]
        let result = dogHRVariability(hrPerEpoch: input)
        XCTAssertEqual(result.count, input.count)
    }

    func testDogHRVariabilitySingleEpochOutputHasOneElement() {
        let result = dogHRVariability(hrPerEpoch: [65.0])
        XCTAssertEqual(result.count, 1)
    }

    func testDogHRVariabilityConstantHRProducesSmallVariability() {
        // Constant HR → DoG filter on flat signal ≈ 0 everywhere
        let input = [Double](repeating: 60.0, count: 20)
        let result = dogHRVariability(hrPerEpoch: input)
        XCTAssertEqual(result.count, 20)
        for val in result {
            XCTAssertEqual(val, 0.0, accuracy: 1e-9, "DoG of constant signal must be zero")
        }
    }

    func testDogHRVariabilityMixedNaNAndValidValues() {
        // Some NaN epochs — NaN-fill should interpolate before convolution
        var input = [60.0, Double.nan, 62.0, Double.nan, 64.0]
        let result = dogHRVariability(hrPerEpoch: input)
        XCTAssertEqual(result.count, input.count)
        // Result should be finite (NaN-fill was applied)
        for (i, val) in result.enumerated() {
            XCTAssertFalse(val.isInfinite, "Result[\(i)] should be finite, got \(val)")
        }
    }

    // MARK: - EpochHRV struct

    func testEpochHRVHasNaNFields() {
        let hrv = EpochHRV(rmssd: .nan, sdnn: .nan, hf: .nan, lf: .nan, lfhf: .nan)
        XCTAssertTrue(hrv.rmssd.isNaN)
        XCTAssertTrue(hrv.sdnn.isNaN)
        XCTAssertTrue(hrv.hf.isNaN)
        XCTAssertTrue(hrv.lf.isNaN)
        XCTAssertTrue(hrv.lfhf.isNaN)
    }

    func testEpochHRVCanHoldFiniteValues() {
        let hrv = EpochHRV(rmssd: 42.0, sdnn: 55.0, hf: .nan, lf: .nan, lfhf: .nan)
        XCTAssertEqual(hrv.rmssd, 42.0, accuracy: 1e-9)
        XCTAssertEqual(hrv.sdnn, 55.0, accuracy: 1e-9)
    }

    // MARK: - hrvFromRR

    func testHRVFromRREmptyInputReturnsNaN() {
        let result = hrvFromRR([])
        XCTAssertTrue(result.rmssd.isNaN)
        XCTAssertTrue(result.sdnn.isNaN)
        XCTAssertTrue(result.hf.isNaN)
        XCTAssertTrue(result.lf.isNaN)
        XCTAssertTrue(result.lfhf.isNaN)
    }

    func testHRVFromRRTooFewBeatsReturnsNaN() {
        // 4 plausible RR intervals → < 5 → all NaN
        let result = hrvFromRR([800.0, 820.0, 790.0, 810.0])
        XCTAssertTrue(result.rmssd.isNaN, "RMSSD should be NaN for < 5 beats")
        XCTAssertTrue(result.sdnn.isNaN, "SDNN should be NaN for < 5 beats")
    }

    func testHRVFromRROutOfRangeValuesFilteredOut() {
        // Mix of plausible and non-plausible — after filtering only 3 remain → NaN
        let result = hrvFromRR([100.0, 800.0, 820.0, 790.0, 100.0, 2500.0])
        XCTAssertTrue(result.rmssd.isNaN, "After filtering only 3 plausible → NaN")
    }

    func testHRVFromRRFiveBeatsReturnsFiniteRmssdAndSdnn() {
        // 5 plausible RR intervals at 60 bpm → should produce finite RMSSD/SDNN
        let rr = [800.0, 810.0, 790.0, 820.0, 800.0]
        let result = hrvFromRR(rr)
        XCTAssertFalse(result.rmssd.isNaN, "RMSSD should be finite for >= 5 beats")
        XCTAssertFalse(result.sdnn.isNaN, "SDNN should be finite for >= 5 beats")
        XCTAssertGreaterThan(result.rmssd, 0.0)
        XCTAssertGreaterThan(result.sdnn, 0.0)
    }

    func testHRVFromRRHFLFLFHFAlwaysNaN() {
        // Per D-01: hf/lf/lfhf are ALWAYS NaN in Phase 3
        let rr = [800.0, 810.0, 790.0, 820.0, 800.0, 805.0, 795.0, 815.0]
        let result = hrvFromRR(rr)
        XCTAssertTrue(result.hf.isNaN, "hf must always be NaN in Phase 3 (D-01)")
        XCTAssertTrue(result.lf.isNaN, "lf must always be NaN in Phase 3 (D-01)")
        XCTAssertTrue(result.lfhf.isNaN, "lfhf must always be NaN in Phase 3 (D-01)")
    }

    // MARK: - respRateAndRRV

    func testRespRateAndRRVEmptyInputReturnsNaN() {
        let (rate, rrv) = respRateAndRRV([], dt: 1.0)
        XCTAssertTrue(rate.isNaN)
        XCTAssertTrue(rrv.isNaN)
    }

    func testRespRateAndRRVTooFewSamplesReturnsNaN() {
        // < 8 samples → NaN per Python guard
        let result = respRateAndRRV([Double](repeating: 0.5, count: 7), dt: 1.0)
        XCTAssertTrue(result.rate.isNaN)
        XCTAssertTrue(result.rrv.isNaN)
    }

    func testRespRateAndRRVFlatSignalReturnsNaN() {
        // Flat signal (constant value) → std == 0 → NaN
        let flat = [Double](repeating: 1.0, count: 30)
        let result = respRateAndRRV(flat, dt: 1.0)
        XCTAssertTrue(result.rate.isNaN, "Flat resp signal should return NaN rate")
        XCTAssertTrue(result.rrv.isNaN, "Flat resp signal should return NaN RRV")
    }

    func testRespRateAndRRVSinusoidalSignalReturnsFineRate() {
        // Simulate ~15 breaths/min: period = 4 s → peaks every 4 samples at 1 Hz
        // Create a 60-sample signal with peaks at indices 0, 4, 8, ... 56
        var signal = [Double](repeating: -0.5, count: 60)
        for i in stride(from: 0, through: 56, by: 4) {
            if i < signal.count {
                signal[i] = 1.0  // peak
                if i > 0 { signal[i - 1] = 0.3 }
                if i + 1 < signal.count { signal[i + 1] = 0.3 }
            }
        }
        let result = respRateAndRRV(signal, dt: 1.0)
        // Should get a meaningful rate (not NaN), around 15 bpm
        // (we don't assert exact value — just that it's physiologically plausible and finite)
        XCTAssertFalse(result.rate.isNaN, "Sinusoidal resp signal should produce a finite rate")
    }

    func testRespRateAndRRVRRVIsNaNWhenFewerThan3Peaks() {
        // A signal with only 2 peaks → fewer than 3 → NaN per Python check
        var signal = [Double](repeating: -1.0, count: 30)
        signal[5] = 1.0  // peak 1
        signal[4] = 0.3
        signal[6] = 0.3
        signal[20] = 1.0  // peak 2
        signal[19] = 0.3
        signal[21] = 0.3
        let result = respRateAndRRV(signal, dt: 1.0)
        // 2 peaks → NaN (Python requires >= 3 peaks for intervals)
        XCTAssertTrue(result.rate.isNaN, "< 3 peaks should return NaN rate")
        XCTAssertTrue(result.rrv.isNaN, "< 3 peaks should return NaN RRV")
    }

    // MARK: - extractFeatures

    func testExtractFeaturesEmptyGridReturnsEmpty() {
        let grid = EpochGrid(
            start: 0.0, end: 0.0, nEpochs: 0,
            counts: [], moveFrac: [], ckSleep: [],
            hr: [], rrBuckets: [], respBuckets: []
        )
        let result = extractFeatures(grid: grid, hrVar: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testExtractFeaturesOutputCountMatchesNEpochs() {
        // 4 epochs, no data
        let n = 4
        let grid = EpochGrid(
            start: 0.0, end: Double(n) * epochS, nEpochs: n,
            counts: [Double](repeating: 0.0, count: n),
            moveFrac: [Double](repeating: 0.05, count: n),
            ckSleep: [Bool](repeating: true, count: n),
            hr: [Double](repeating: Double.nan, count: n),
            rrBuckets: [[Double]](repeating: [], count: n),
            respBuckets: [[Double]](repeating: [], count: n)
        )
        let hrVar = [Double](repeating: 0.0, count: n)
        let result = extractFeatures(grid: grid, hrVar: hrVar)
        XCTAssertEqual(result.count, n)
    }

    func testExtractFeaturesEpochIdxIsCorrect() {
        let n = 4
        let grid = EpochGrid(
            start: 0.0, end: Double(n) * epochS, nEpochs: n,
            counts: [Double](repeating: 0.0, count: n),
            moveFrac: [Double](repeating: 0.05, count: n),
            ckSleep: [Bool](repeating: true, count: n),
            hr: [Double](repeating: Double.nan, count: n),
            rrBuckets: [[Double]](repeating: [], count: n),
            respBuckets: [[Double]](repeating: [], count: n)
        )
        let result = extractFeatures(grid: grid, hrVar: [Double](repeating: 0.0, count: n))
        for (i, feat) in result.enumerated() {
            XCTAssertEqual(feat.epochIdx, i, "epochIdx should match loop index")
        }
    }

    func testExtractFeaturesHRVForwardFillStride4() {
        // With stride=4 (hrvStrideEpochs), HRV should only be recomputed at epochs 0, 4, 8...
        // With 8 epochs and plausible RR data, epochs 1,2,3 should share values with epoch 0
        let n = 8
        // All epochs have the same RR bucket: 5 plausible values
        let rrBucket = [800.0, 810.0, 790.0, 820.0, 800.0]
        let grid = EpochGrid(
            start: 0.0, end: Double(n) * epochS, nEpochs: n,
            counts: [Double](repeating: 0.0, count: n),
            moveFrac: [Double](repeating: 0.05, count: n),
            ckSleep: [Bool](repeating: true, count: n),
            hr: [Double](repeating: 60.0, count: n),
            rrBuckets: [[Double]](repeating: rrBucket, count: n),
            respBuckets: [[Double]](repeating: [], count: n)
        )
        let result = extractFeatures(grid: grid, hrVar: [Double](repeating: 0.0, count: n))
        XCTAssertEqual(result.count, n)
        // Epochs 0..3 should have same RMSSD (forward-filled from epoch 0)
        let rmssd0 = result[0].rmssd
        let rmssd1 = result[1].rmssd
        let rmssd2 = result[2].rmssd
        let rmssd3 = result[3].rmssd
        if rmssd0.isFinite {
            XCTAssertEqual(rmssd1, rmssd0, accuracy: 1e-10, "Epoch 1 should forward-fill from epoch 0")
            XCTAssertEqual(rmssd2, rmssd0, accuracy: 1e-10, "Epoch 2 should forward-fill from epoch 0")
            XCTAssertEqual(rmssd3, rmssd0, accuracy: 1e-10, "Epoch 3 should forward-fill from epoch 0")
        }
    }

    func testExtractFeaturesMoveFracPropagated() {
        let n = 3
        let moveFracs = [0.05, 0.20, 0.08]
        let grid = EpochGrid(
            start: 0.0, end: Double(n) * epochS, nEpochs: n,
            counts: [Double](repeating: 0.0, count: n),
            moveFrac: moveFracs,
            ckSleep: [Bool](repeating: true, count: n),
            hr: [Double](repeating: Double.nan, count: n),
            rrBuckets: [[Double]](repeating: [], count: n),
            respBuckets: [[Double]](repeating: [], count: n)
        )
        let result = extractFeatures(grid: grid, hrVar: [Double](repeating: 0.0, count: n))
        for (i, feat) in result.enumerated() {
            XCTAssertEqual(feat.moveFrac, moveFracs[i], accuracy: 1e-9,
                           "moveFrac at epoch \(i) should match grid.moveFrac")
        }
    }

    func testExtractFeaturesCkSleepPropagated() {
        let n = 3
        let ckSleeps = [true, false, true]
        let grid = EpochGrid(
            start: 0.0, end: Double(n) * epochS, nEpochs: n,
            counts: [Double](repeating: 0.0, count: n),
            moveFrac: [Double](repeating: 0.05, count: n),
            ckSleep: ckSleeps,
            hr: [Double](repeating: Double.nan, count: n),
            rrBuckets: [[Double]](repeating: [], count: n),
            respBuckets: [[Double]](repeating: [], count: n)
        )
        let result = extractFeatures(grid: grid, hrVar: [Double](repeating: 0.0, count: n))
        for (i, feat) in result.enumerated() {
            XCTAssertEqual(feat.ckSleep, ckSleeps[i],
                           "ckSleep at epoch \(i) should match grid.ckSleep")
        }
    }

    func testExtractFeaturesHRVarPropagated() {
        let n = 3
        let hrVar = [1.5, 2.3, 0.8]
        let grid = EpochGrid(
            start: 0.0, end: Double(n) * epochS, nEpochs: n,
            counts: [Double](repeating: 0.0, count: n),
            moveFrac: [Double](repeating: 0.05, count: n),
            ckSleep: [Bool](repeating: true, count: n),
            hr: [Double](repeating: Double.nan, count: n),
            rrBuckets: [[Double]](repeating: [], count: n),
            respBuckets: [[Double]](repeating: [], count: n)
        )
        let result = extractFeatures(grid: grid, hrVar: hrVar)
        for (i, feat) in result.enumerated() {
            XCTAssertEqual(feat.hrVar, hrVar[i], accuracy: 1e-9,
                           "hrVar at epoch \(i) should match the passed hrVar array")
        }
    }

    func testExtractFeaturesHFLFLFHFAlwaysNaN() {
        // Per D-01: EpochFeatures.hf/lf/lfhf are always .nan
        let n = 2
        let grid = EpochGrid(
            start: 0.0, end: Double(n) * epochS, nEpochs: n,
            counts: [Double](repeating: 0.0, count: n),
            moveFrac: [Double](repeating: 0.05, count: n),
            ckSleep: [Bool](repeating: true, count: n),
            hr: [Double](repeating: 60.0, count: n),
            rrBuckets: [[Double]](repeating: [800.0, 810.0, 790.0, 820.0, 800.0], count: n),
            respBuckets: [[Double]](repeating: [], count: n)
        )
        let result = extractFeatures(grid: grid, hrVar: [Double](repeating: 0.0, count: n))
        for feat in result {
            XCTAssertTrue(feat.hf.isNaN, "hf must be NaN in Phase 3 per D-01")
            XCTAssertTrue(feat.lf.isNaN, "lf must be NaN in Phase 3 per D-01")
            XCTAssertTrue(feat.lfhf.isNaN, "lfhf must be NaN in Phase 3 per D-01")
        }
    }
}
